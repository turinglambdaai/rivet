#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         "../rivet/distribution/crypto.rkt"
         "linux-package.rkt"
         "package.rkt"
         "project.rkt"
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

(define (write-wix-source! project package source)
  (define name (project-name project))
  (define identifier (project-identifier project))
  (define display-name (project-display-name project))
  (define publisher (project-publisher project))
  (define schemes (project-url-schemes project))
  (define associations (project-file-associations project))
  (define registrations? (or (pair? schemes) (pair? associations)))
  (call-with-output-file source
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Wix xmlns=\"http://wixtoolset.org/schemas/v4/wxs\">\n  <Package Name=\"~a\" Manufacturer=\"~a\" Version=\"~a\" UpgradeCode=\"~a\" Scope=\"perMachine\">\n    <MajorUpgrade DowngradeErrorMessage=\"A newer version is already installed.\" />\n    <MediaTemplate EmbedCab=\"yes\" />\n    <Feature Id=\"Main\"><ComponentGroupRef Id=\"ProductComponents\" /><ComponentGroupRef Id=\"ShortcutComponents\" /></Feature>\n  </Package>\n  <Fragment><StandardDirectory Id=\"ProgramFiles6432Folder\"><Directory Id=\"INSTALLFOLDER\" Name=\"~a\" /></StandardDirectory></Fragment>\n  <Fragment><StandardDirectory Id=\"ProgramMenuFolder\"><Directory Id=\"ApplicationProgramsFolder\" Name=\"~a\" /></StandardDirectory><StandardDirectory Id=\"DesktopFolder\" /></Fragment>\n  <Fragment><ComponentGroup Id=\"ShortcutComponents\" Directory=\"ApplicationProgramsFolder\">\n    <Component Id=\"StartMenuShortcutComponent\" Guid=\"*\">\n      <Shortcut Id=\"StartMenuApplicationShortcut\" Name=\"~a\" Description=\"~a\" Target=\"[INSTALLFOLDER]RivetHost.exe\" WorkingDirectory=\"INSTALLFOLDER\" />\n      <RemoveFolder Id=\"RemoveApplicationProgramsFolder\" Directory=\"ApplicationProgramsFolder\" On=\"uninstall\" />\n      <RegistryValue Root=\"HKLM\" Key=\"Software\\~a\\Shortcuts\" Name=\"StartMenu\" Type=\"integer\" Value=\"1\" KeyPath=\"yes\" />\n    </Component>\n    <Component Id=\"DesktopShortcutComponent\" Guid=\"*\" Directory=\"DesktopFolder\">\n      <Shortcut Id=\"DesktopApplicationShortcut\" Name=\"~a\" Description=\"~a\" Target=\"[INSTALLFOLDER]RivetHost.exe\" WorkingDirectory=\"INSTALLFOLDER\" />\n      <RegistryValue Root=\"HKLM\" Key=\"Software\\~a\\Shortcuts\" Name=\"Desktop\" Type=\"integer\" Value=\"1\" KeyPath=\"yes\" />\n    </Component>\n  </ComponentGroup></Fragment>\n  <Fragment><ComponentGroup Id=\"ProductComponents\" Directory=\"INSTALLFOLDER\">\n"
               (xml-escape display-name)
               (xml-escape publisher)
               (xml-escape (project-version project))
               (upgrade-code-for identifier)
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

(define (create-windows-installer! project package production?)
  (define wix (or (find-executable-path "wix")
                  (find-executable-path "wix.exe")))
  (unless wix
    (error 'create-installer!
           "WiX Toolset v4+ was not found; install `wix tool install --global wix` before creating an MSI"))
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
  (run! 'create-installer! wix "build" "-arch" architecture
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
  (when (file-exists? output) (delete-file output))
  (run! 'create-installer! hdiutil "create" "-fs" "HFS+" "-format" "UDZO"
        "-volname" (project-display-name project)
        "-srcfolder" (path->string app)
        (path->string output))
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
  output)

(define (create-installer! project package #:production? [production? #f])
  (case (system-type 'os)
    [(windows) (create-windows-installer! project package production?)]
    [(macosx) (create-macos-installer! project package production?)]
    [(unix) (create-linux-installer! project package production?)]
    [else (error 'create-installer! "installers target Windows, macOS, and Linux")]))

(module+ test-support
  (provide write-wix-source!
           upgrade-code-for))
