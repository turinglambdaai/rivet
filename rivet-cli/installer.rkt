#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "../rivet/distribution/crypto.rkt"
         "appimage.rkt"
         "deb.rkt"
         "linux-package.rkt"
         "package.rkt"
         "project.rkt"
         "rpm.rkt"
         "signing-options.rkt"
         "tar.rkt")

(provide create-installer!)

(define (run! who executable . arguments)
  (unless executable (error who "required executable was not found"))
  (unless (apply system* executable arguments)
    (raise-arguments-error who
                           "external command failed"
                           "executable" executable
                           "arguments" arguments)))

(define (xml-escape value)
  (regexp-replace*
   #px"[&<>\"]" value
   (lambda (match)
     (case (string-ref match 0)
       [(#\&) "&amp;"] [(#\<) "&lt;"] [(#\>) "&gt;"] [else "&quot;"]))))

;; Every project must own its UpgradeCode or two Rivet apps would treat each
;; other as upgrades and silently replace one another. Derive a stable GUID
;; from the project identifier under a fixed Rivet installer namespace (any
;; stable GUID serves here; it is not a registered RFC namespace). The digest
;; is SHA-256 rather than the RFC 4122 v5 SHA-1 so no extra dependency is
;; pulled in; the version/variant nibbles are still set so the value is a
;; well-formed UUID everywhere GUIDs are displayed.
(define upgrade-code-namespace
  "b2a3c0de5f4e4a678b2c1d0e9f6a7b88")

(define (digest->hex digest)
  (string-append*
   (for/list ([byte (in-bytes digest)])
     (string (string-ref "0123456789abcdef" (quotient byte 16))
             (string-ref "0123456789abcdef" (remainder byte 16))))))

(define (upgrade-code-for identifier)
  (define digest
    (sha256-bytes (bytes-append (string->bytes/utf-8 upgrade-code-namespace)
                                (string->bytes/utf-8 identifier))))
  (define hex (digest->hex digest))
  (define variant
    (string-ref "89ab" (remainder (string->number (substring hex 16 17) 16) 4)))
  (string-append (substring hex 0 8) "-" (substring hex 8 12) "-"
                 "5" (substring hex 13 16) "-"
                 (string variant) (substring hex 17 20) "-"
                 (substring hex 20 32)))

(define (wix-id prefix value)
  (string-append prefix
                 (regexp-replace* #px"[^A-Za-z0-9_.]" value "_")))

(define (relative-files root)
  (sort
   (for/list ([path (in-list (find-files file-exists? root))])
     (find-relative-path root path))
   string<?
   #:key path->string))

;; ---------------------------------------------------------------------------
;; MSI license page

(define default-license-notice
  "This software is distributed under the terms of its accompanying license. The complete license text ships with the application. By continuing the installation you accept those terms.")

(define (rtf-escape-char ch)
  (define code (char->integer ch))
  (case ch
    [(#\\) "\\\\"]
    [(#\{) "\\{"]
    [(#\}) "\\}"]
    [(#\newline) "\\par\n"]
    [(#\return) ""]
    [(#\tab) "\\tab "]
    [else
     (cond
       [(< code 128) (string ch)]
       ;; RTF \uN takes a signed 16-bit code unit.
       [(<= code #xFFFF)
        (format "\\u~a?" (if (>= code #x8000) (- code #x10000) code))]
       [else
        (define value (- code #x10000))
        (format "\\u~a?\\u~a?"
                (+ #xD800 (quotient value #x400))
                (+ #xDC00 (remainder value #x400)))])]))

(define (text->rtf text)
  (string-append
   "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss\\fcharset0 Segoe UI;}}\\fs18 "
   (apply string-append (map rtf-escape-char (string->list text)))
   "\\par}"))

(define (project-license-text project)
  (for/or ([name (in-list '("LICENSE" "LICENSE.txt" "COPYING" "COPYING.txt"))])
    (define candidate (project-path project name))
    (and (file-exists? candidate)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (file->string candidate)))))

;; The wizard's license page always needs an RTF: the configured file is used
;; verbatim, otherwise the repository license text renders into RTF, and a
;; project with neither gets a neutral notice. The generated file lands next
;; to product.wxs in the scratch tree, never in the project source.
(define (resolve-wix-license! project source)
  (define configured (project-windows-license project))
  (if configured
      (let ([path (project-path project configured)])
        (unless (file-exists? path)
          (raise-arguments-error 'write-wix-source!
                                 "configured windows license does not exist"
                                 "license" configured
                                 "source" path))
        path)
      (let ([generated (build-path (path-only source) "license.rtf")])
        (make-parent-directory* generated)
        (call-with-output-file generated
          #:exists 'truncate/replace
          (lambda (out)
            (display (text->rtf (or (project-license-text project)
                                    default-license-notice))
                     out)))
        generated)))

(define (write-wix-source! project package source)
  (define name (project-name project))
  (define identifier (project-identifier project))
  (define display-name (project-display-name project))
  (define publisher (project-publisher project))
  (define schemes (project-url-schemes project))
  (define associations (project-file-associations project))
  (define registrations? (or (pair? schemes) (pair? associations)))
  ;; Add/Remove Programs shows a generic tile unless the package pins an
  ;; icon; the shortcuts and the exe already carry the resource icon. The
  ;; elements must author as direct Package children: WiX drops unreferenced
  ;; fragments, so a standalone Icon/Property fragment never reaches the MSI.
  (define icon-xml
    (let* ([configured (project-windows-icon project)]
           [icon (and configured (project-path project configured))])
      (when icon
        (unless (file-exists? icon)
          (raise-arguments-error 'write-wix-source!
                                 "configured windows icon does not exist"
                                 "icon" configured
                                 "source" icon)))
      (if icon
          (format "    <Icon Id=\"RivetAppIcon.ico\" SourceFile=\"~a\" />\n    <Property Id=\"ARPPRODUCTICON\" Value=\"RivetAppIcon.ico\" />\n"
                  (xml-escape (path->string icon)))
          "")))
  (define license-path (resolve-wix-license! project source))
  (define bitmaps (project-windows-installer-bitmaps project))
  (define (bitmap-variable wix-id key)
    (define configured (hash-ref bitmaps key #f))
    (and configured
         (let ([path (project-path project configured)])
           (unless (file-exists? path)
             (raise-arguments-error 'write-wix-source!
                                    "configured windows installer bitmap does not exist"
                                    "bitmap" configured
                                    "source" path))
           (format "    <WixVariable Id=\"~a\" Value=\"~a\" />\n"
                   wix-id
                   (xml-escape (path->string path))))))
  ;; The standard install-dir wizard sequence (welcome, license, directory,
  ;; progress, exit) plus the launch checkbox on the finish page. Stock UI
  ;; sets are consumed through the UI extension's namespace element; the
  ;; launch action is the Util extension's WixShellExec with an
  ;; architecture-specific CA binary.
  (define installer-ui-xml
    (format (string-append
             "    <WixVariable Id=\"WixUILicenseRtf\" Value=\"~a\" />\n"
             "~a~a"
             "    <Property Id=\"WIXUI_INSTALLDIR\" Value=\"INSTALLFOLDER\" />\n"
             "    <Property Id=\"WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT\" Value=\"~a\" />\n"
             "    <Property Id=\"WixShellExecTarget\" Value=\"[INSTALLFOLDER]RivetHost.exe\" />\n"
             "    <CustomAction Id=\"LaunchApplication\" BinaryRef=\"Wix4UtilCA_~a\" DllEntry=\"WixShellExec\" Impersonate=\"yes\" />\n"
             "    <ui:WixUI Id=\"WixUI_InstallDir\" />\n"
             "    <UI>\n"
             "      <Publish Dialog=\"ExitDialog\" Control=\"Finish\" Event=\"DoAction\" Value=\"LaunchApplication\" Condition=\"WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 and NOT Installed\" Order=\"2\" />\n"
             "    </UI>\n")
            (xml-escape (path->string license-path))
            (or (bitmap-variable "WixUIBannerBmp" 'banner) "")
            (or (bitmap-variable "WixUIDialogBmp" 'dialog) "")
            (xml-escape (string-append "Launch " display-name))
            (case (system-type 'arch)
              [(aarch64 arm64) "ARM64"]
              [else "X64"])))
  (call-with-output-file source
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Wix xmlns=\"http://wixtoolset.org/schemas/v4/wxs\" xmlns:ui=\"http://wixtoolset.org/schemas/v4/wxs/ui\">\n  <Package Name=\"~a\" Manufacturer=\"~a\" Version=\"~a\" UpgradeCode=\"~a\" Scope=\"perMachine\">\n    <MajorUpgrade DowngradeErrorMessage=\"A newer version is already installed.\" />\n    <MediaTemplate EmbedCab=\"yes\" />\n    <Feature Id=\"Main\"><ComponentGroupRef Id=\"ProductComponents\" /><ComponentGroupRef Id=\"ShortcutComponents\" /></Feature>\n~a~a  </Package>\n  <Fragment><StandardDirectory Id=\"ProgramFiles6432Folder\"><Directory Id=\"INSTALLFOLDER\" Name=\"~a\" /></StandardDirectory></Fragment>\n  <Fragment><StandardDirectory Id=\"ProgramMenuFolder\"><Directory Id=\"ApplicationProgramsFolder\" Name=\"~a\" /></StandardDirectory><StandardDirectory Id=\"DesktopFolder\" /></Fragment>\n  <Fragment><ComponentGroup Id=\"ShortcutComponents\" Directory=\"ApplicationProgramsFolder\">\n    <Component Id=\"StartMenuShortcutComponent\" Guid=\"*\">\n      <Shortcut Id=\"StartMenuApplicationShortcut\" Name=\"~a\" Description=\"~a\" Target=\"[INSTALLFOLDER]RivetHost.exe\" WorkingDirectory=\"INSTALLFOLDER\" />\n      <RemoveFolder Id=\"RemoveApplicationProgramsFolder\" Directory=\"ApplicationProgramsFolder\" On=\"uninstall\" />\n      <RegistryValue Root=\"HKLM\" Key=\"Software\\~a\\Shortcuts\" Name=\"StartMenu\" Type=\"integer\" Value=\"1\" KeyPath=\"yes\" />\n    </Component>\n    <Component Id=\"DesktopShortcutComponent\" Guid=\"*\" Directory=\"DesktopFolder\">\n      <Shortcut Id=\"DesktopApplicationShortcut\" Name=\"~a\" Description=\"~a\" Target=\"[INSTALLFOLDER]RivetHost.exe\" WorkingDirectory=\"INSTALLFOLDER\" />\n      <RegistryValue Root=\"HKLM\" Key=\"Software\\~a\\Shortcuts\" Name=\"Desktop\" Type=\"integer\" Value=\"1\" KeyPath=\"yes\" />\n    </Component>\n  </ComponentGroup></Fragment>\n  <Fragment><ComponentGroup Id=\"ProductComponents\" Directory=\"INSTALLFOLDER\">\n"
               (xml-escape display-name)
               (xml-escape publisher)
               (xml-escape (project-version project))
               (upgrade-code-for identifier)
               icon-xml
               installer-ui-xml
               (xml-escape name)
               (xml-escape display-name)
               (xml-escape display-name)
               (xml-escape display-name)
               (xml-escape identifier)
               (xml-escape display-name)
               (xml-escape display-name)
               (xml-escape identifier))
      ;; WiX v4 recursively harvests the verified package at build time,
      ;; preserving the runtime/res hierarchy without a second file list.
      (fprintf out "    <Files Include=\"~a\\**\" />\n"
               (xml-escape (path->string package)))
      (when registrations?
        (display "    <Component Id=\"NativeActivationRegistration\" Guid=\"*\">\n" out)
        (define key-path? #t)
        (define (registry key name value)
          (fprintf out
                   "      <RegistryValue Root=\"HKCU\" Key=\"~a\"~a Type=\"string\" Value=\"~a\"~a />\n"
                   (xml-escape key)
                   (if (string=? name "")
                       ""
                       (format " Name=\"~a\"" (xml-escape name)))
                   (xml-escape value)
                   (if key-path? " KeyPath=\"yes\"" ""))
          (set! key-path? #f))
        (for ([scheme (in-list schemes)])
          (define root (string-append "Software\\Classes\\" scheme))
          (registry root "" (string-append "URL:" scheme))
          (registry root "URL Protocol" "")
          (registry (string-append root "\\shell\\open\\command") ""
                    "\"[INSTALLFOLDER]RivetHost.exe\" \"%1\""))
        (for ([association (in-list associations)])
          (define extension (hash-ref association 'extension))
          (define class (string-append identifier extension))
          (registry (string-append "Software\\Classes\\" extension) "" class)
          (registry (string-append "Software\\Classes\\" class) ""
                    (hash-ref association 'description
                              (lambda () (string-append (project-display-name project)
                                                        " Document"))))
          (registry (string-append "Software\\Classes\\" class
                                   "\\shell\\open\\command") ""
                    "\"[INSTALLFOLDER]RivetHost.exe\" \"%1\""))
        (display "    </Component>\n" out))
      (display "  </ComponentGroup></Fragment>\n</Wix>\n" out))))

;; The wizard's install-dir sequence and the launch action live in the UI and
;; Util extensions. The wix CLI resolves -ext references only from its local
;; extension cache, so the matching extension versions are installed on
;; demand right before the build.
(define (ensure-wix-extensions! who wix)
  (define version-output
    (with-output-to-string (lambda () (system* wix "--version"))))
  (define version-match (regexp-match #px"^[0-9]+\\.[0-9]+\\.[0-9]+" version-output))
  (define version (and version-match (car version-match)))
  (for ([extension (in-list '("WixToolset.UI.wixext" "WixToolset.Util.wixext"))])
    (run! who wix "extension" "add" "-g"
          (if version (string-append extension "/" version) extension))))

(define (create-windows-installer! project package production?)
  (define wix (or (find-executable-path "wix")
                  (find-executable-path "wix.exe")))
  (unless wix
    (error 'create-installer!
           "WiX Toolset was not found; install it with `dotnet tool install --global wix --version 5.*` (WiX 7 aborts with WIX7015 unless the Open Source Maintenance Fee EULA is accepted, so pin the 5.x line)"))
  (define dist (project-path project "dist"))
  (define source (project-path project ".rivet" "installer" "product.wxs"))
  (make-parent-directory* source)
  (write-wix-source! project package source)
  (define architecture
    (case (system-type 'arch) [(aarch64 arm64) "arm64"] [else "x64"]))
  (define output
    (build-path dist
                (format "~a-~a-windows-~a.msi"
                        (project-name project)
                        (project-version project)
                        architecture)))
  (ensure-wix-extensions! 'create-installer! wix)
  (run! 'create-installer! wix "build" "-arch" architecture
        "-ext" "WixToolset.UI.wixext"
        "-ext" "WixToolset.Util.wixext"
        "-o" (path->string output) (path->string source))
  (when production?
    (sign-windows-production! output (load-windows-production-signing)))
  output)

(define (create-macos-installer! project app production?)
  (define hdiutil (find-executable-path "hdiutil"))
  (unless hdiutil (error 'create-installer! "hdiutil was not found"))
  (define output
    (project-path project "dist"
                  (format "~a-~a-macos.dmg"
                          (project-name project)
                          (project-version project))))
  (make-directory* (project-path project "dist"))
  (when (file-exists? output) (delete-file output))
  (if (project-dmg-background project)
      (create-branded-macos-dmg! project app output hdiutil)
      (run! 'create-installer! hdiutil "create" "-fs" "HFS+" "-format" "UDZO"
            "-volname" (project-display-name project)
            "-srcfolder" (path->string app)
            (path->string output)))
  (when production?
    (define settings (load-macos-production-signing))
    (run! 'create-installer! (find-executable-path "codesign")
          "--force" "--timestamp" "--sign"
          (macos-signing-identity settings) (path->string output))
    (define xcrun (find-executable-path "xcrun"))
    (run! 'create-installer! xcrun "notarytool" "submit"
          (path->string output) "--keychain-profile"
          (macos-signing-notary-profile settings) "--wait")
    (run! 'create-installer! xcrun "stapler" "staple" (path->string output)))
  output)

;; Branded DMG layout constants. The window geometry matches the generated
;; background artwork aspect ratio (products render 1320x800 PNGs for the
;; 660x400 window), and both icons sit on the horizontal midline.
(define dmg-window-origin-x 200)
(define dmg-window-origin-y 120)
(define dmg-window-width 660)
(define dmg-window-height 400)
(define dmg-icon-size 80)
(define dmg-app-icon-position '(130 . 160))
(define dmg-applications-icon-position '(450 . 160))

(define (applescript-escape value)
  (regexp-replace* #px"[\\\\\"]" value (lambda (m) (string-append "\\" m))))

;; The volume style can only be authored through Finder's AppleScript
;; interface (.DS_Store icon views have no hdiutil switches), so the layout
;; script is generated per project and run against the attached read/write
;; image. Window bounds are screen coordinates; icon positions are window
;; coordinates.
(define (dmg-style-applescript volume-name app-name
                               #:window-origin [origin-x dmg-window-origin-x]
                               [origin-y dmg-window-origin-y])
  (define bottom-right
    (format "{~a, ~a, ~a, ~a}"
            origin-x origin-y
            (+ origin-x dmg-window-width)
            (+ origin-y dmg-window-height)))
  (format (string-append
           "tell application \"Finder\"\n"
           "\ttell disk \"~a\"\n"
           "\t\topen\n"
           "\t\tset current view of container window to icon view\n"
           "\t\tset statusbar visible of container window to false\n"
           "\t\tset theViewOptions to the icon view options of container window\n"
           "\t\tset arrangement of theViewOptions to not arranged\n"
           "\t\tset icon size of theViewOptions to ~a\n"
           "\t\tset background picture of theViewOptions to file \".background:background.png\"\n"
           "\t\tset bounds of container window to ~a\n"
           "\t\tset position of item \"~a\" of container window to {~a, ~a}\n"
           "\t\tset position of item \"Applications\" of container window to {~a, ~a}\n"
           "\t\tclose\n"
           "\t\tupdate\n"
           "\tend tell\n"
           "end tell\n")
          (applescript-escape volume-name)
          dmg-icon-size
          bottom-right
          (applescript-escape app-name)
          (car dmg-app-icon-position) (cdr dmg-app-icon-position)
          (car dmg-applications-icon-position) (cdr dmg-applications-icon-position)))

(define (delete-optional! path)
  (when (file-exists? path) (delete-file path))
  (when (directory-exists? path) (delete-directory/files path)))

;; Commercial drag-to-install image: stage the volume contents (bundle,
;; /Applications link, hidden background asset), attach a read/write image,
;; let Finder size the window and place both icons, then convert to the
;; compressed output. Projects without a declared background keep the plain
;; single-folder image instead.
(define (create-branded-macos-dmg! project app output hdiutil)
  (define background (project-path project (project-dmg-background project)))
  (unless (file-exists? background)
    (raise-arguments-error 'create-installer!
                           "configured dmg background does not exist"
                           "background" (project-dmg-background project)
                           "source" background))
  (define scratch (project-path project ".rivet" "installer"))
  (define staging (build-path scratch "dmg-staging"))
  (define staging-app (build-path staging (file-name-from-path app)))
  (define rw-image (build-path scratch "dmg-rw.dmg"))
  (define script-path (build-path scratch "dmg-style.applescript"))
  (define volume-name (project-display-name project))
  (define app-name (path->string (file-name-from-path app)))
  (delete-directory/files staging #:must-exist? #f)
  (make-directory* staging)
  (copy-directory/files app staging-app)
  (make-file-or-directory-link "/Applications"
                               (build-path staging "Applications"))
  (make-directory* (build-path staging ".background"))
  (copy-file background (build-path staging ".background" "background.png"))
  (delete-optional! rw-image)
  (run! 'create-installer! hdiutil "create" "-fs" "HFS+" "-volname" volume-name
        "-srcfolder" (path->string staging)
        "-format" "UDRW" "-ov" (path->string rw-image))
  ;; Mount through /Volumes: Finder only addresses volumes there, which the
  ;; layout script relies on. The mounted name can drift from the requested
  ;; volume name when a same-named volume is already present, so the script
  ;; addresses the resolved disk.
  (define attach-output
    (with-output-to-string
      (lambda ()
        (run! 'create-installer! hdiutil "attach" (path->string rw-image)
              "-noautoopen" "-readwrite"))))
  (define mount-path
    (let* ([line (last (string-split (string-trim attach-output) "\n"))]
           [fields (string-split line "\t")])
      (string-trim (last fields))))
  (define disk-name (last (string-split mount-path "/")))
  (call-with-output-file script-path
    #:exists 'truncate/replace
    (lambda (out)
      (display (dmg-style-applescript disk-name app-name) out)))
  (define (detach!)
    (with-handlers ([exn:fail? (lambda (_)
                                 (run! 'create-installer! hdiutil "detach"
                                       "-force" mount-path))])
      (run! 'create-installer! hdiutil "detach" mount-path)))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (with-handlers ([exn:fail? void]) (detach!))
                     (raise e))])
    (run! 'create-installer! (find-executable-path "osascript")
          (path->string script-path))
    (when (find-executable-path "sync")
      (run! 'create-installer! (find-executable-path "sync")))
    (detach!))
  (run! 'create-installer! hdiutil "convert" (path->string rw-image)
        "-format" "UDZO" "-ov" "-o" (path->string output))
  (delete-optional! rw-image)
  (delete-directory/files staging)
  output)

(define (create-linux-installer! project package production?)
  (define output (linux-installer-path project))
  (make-directory* (project-path project "dist"))
  ;; The archive root keeps the verified package's own name so extraction is
  ;; self-contained, mirroring the DMG's top-level application directory.
  (define archive
    (gzip-archive-bytes
     (tar-directory->bytes
      package
      #:root-name (path->string (file-name-from-path package)))))
  (call-with-output-file output
    #:exists 'truncate/replace
    (lambda (out) (write-bytes archive out)))
  (when production?
    (define settings (load-linux-production-signing))
    (define signature
      (ed25519-sign
       (read-ed25519-private-key
        (string->path (linux-signing-private-key settings)))
       archive))
    (call-with-output-file (string-append (path->string output) ".sig")
      #:exists 'truncate/replace
      (lambda (out)
        (displayln (bytes->base64-string signature) out))))
  ;; Native system installer formats ride along with the signed tar.gz:
  ;; deb/rpm integrate with the distribution package manager, while AppImage
  ;; carries its own GTK4 dependency closure and becomes the signed in-place
  ;; update payload when enabled.
  (for ([format (in-list (project-linux-formats project))])
    (case format
      [("deb") (create-deb! project package)]
      [("rpm") (create-rpm! project package)]
      [("appimage") (create-appimage! project package)]))
  output)

(define (create-installer! project package #:production? [production? #f])
  (case (system-type 'os)
    [(windows) (create-windows-installer! project package production?)]
    [(macosx) (create-macos-installer! project package production?)]
    [(unix) (create-linux-installer! project package production?)]
    [else (error 'create-installer! "installers target Windows, macOS, and Linux")]))

(module+ test-support
  (provide write-wix-source!
           upgrade-code-for
           ensure-wix-extensions!
           text->rtf
           dmg-style-applescript
           create-macos-installer!))
