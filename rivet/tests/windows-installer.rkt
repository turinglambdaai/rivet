#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         rackunit
         "../../rivet/distribution/crypto.rkt"
         "../../rivet-cli/installer.rkt"
         "../../rivet-cli/project.rkt"
         (submod "../../rivet-cli/installer.rkt" test-support))

;; Derived UpgradeCodes are content-addressed through the pinned libcrypto
;; factory, and every WiX source embeds them. Package build hosts may not
;; have a native libcrypto, so the whole file skips there; it runs in
;; rivet's CI and on desktop hosts.
(define digests-available?
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (sha256-bytes #"")
    #t))
(unless digests-available?
  (displayln
   "rivet-windows-installer-tests: skipping; no libcrypto provider")
  (exit 0))

;; ---------------------------------------------------------------------------
;; Derived UpgradeCodes

(define (uuid-shape? value)
  (regexp-match? #px"^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
                 value))
(check-true (uuid-shape? (upgrade-code-for "site.jrtx.podlens"))
            "derived upgrade codes must be RFC 4122 v5-shaped UUIDs")
(check-equal? (upgrade-code-for "site.jrtx.podlens")
              (upgrade-code-for "site.jrtx.podlens")
              "the same identifier must always derive the same upgrade code")
(check-not-equal? (upgrade-code-for "site.jrtx.podlens")
                  (upgrade-code-for "site.jrtx.payback")
                  "different products must never share an upgrade code")

;; ---------------------------------------------------------------------------
;; WiX source content

(define package-root (make-temporary-file "rivet-windows-installer-~a" 'directory))
(define package (build-path package-root "Smoke-windows-x64"))
(make-directory* package)
(call-with-output-file (build-path package "RivetHost.exe")
  #:exists 'truncate/replace (lambda (out) (display "fake-exe" out)))

(define (wix-source-for overrides)
  (define project
    (rivet-project package-root
                   (hash-union (hasheq 'name "Smoke") overrides)))
  (define source (build-path package-root ".rivet" "installer" "product.wxs"))
  (make-parent-directory* source)
  (write-wix-source! project package source)
  (file->string source))

(define (hash-union a b)
  (for/fold ([acc a]) ([(key value) (in-hash b)]) (hash-set acc key value)))

(define plain-source (wix-source-for (hasheq)))

(check-regexp-match #rx"<Package Name=\"Smoke\" Manufacturer=\"Smoke\"" plain-source
                    "legacy projects must use the display name as their publisher")
(check-regexp-match #rx"Scope=\"perMachine\"" plain-source
                    "the existing elevated installation scope must remain explicit")
(check-regexp-match #px"UpgradeCode=\"[0-9a-f]{8}-" plain-source
                    "the upgrade code must be derived, not the shared hardcoded constant")
(check-false (regexp-match? #rx"6B7D0F2E-8B9D-4FB5-9F69-1B12E50F60C1" plain-source)
             "the legacy shared upgrade code must be gone")
(check-regexp-match #rx"<ComponentGroupRef Id=\"ShortcutComponents\" />" plain-source
                    "the main feature must install the shortcuts")
(check-regexp-match #rx"<StandardDirectory Id=\"ProgramMenuFolder\"><Directory Id=\"ApplicationProgramsFolder\"" plain-source)
(check-regexp-match #rx"<StandardDirectory Id=\"DesktopFolder\"" plain-source)
(check-equal? (length (regexp-match* #rx"<Shortcut Id=" plain-source)) 2
              "a start-menu and a desktop shortcut must be authored")
(check-regexp-match
 #rx"<Shortcut Id=\"StartMenuApplicationShortcut\" Name=\"Smoke\" Description=\"Smoke\" Target=\"\\[INSTALLFOLDER\\]RivetHost.exe\" WorkingDirectory=\"INSTALLFOLDER\" />"
 plain-source)
(check-equal? (length (regexp-match* #rx"<RemoveFolder Id=\"RemoveApplicationProgramsFolder\"" plain-source)) 1
              "the start-menu folder must be removed on uninstall")
(check-equal? (length (regexp-match* #rx"<RegistryValue Root=\"HKLM\" Key=\"Software\\\\[^\"]+\\\\Shortcuts\"" plain-source)) 2
              "shortcut components must carry a machine-scoped key path")

;; Display names and identifiers are XML-escaped everywhere they are emitted.
(define escaped-source
  (wix-source-for (hasheq 'display-name "Smoke & Stack"
                          'publisher "Example <Apps> & Co."
                          'identifier "dev.rivet.smoke-test")))
(check-regexp-match #rx"Name=\"Smoke &amp; Stack\"" escaped-source
                    "display names must be XML-escaped")
(check-regexp-match #rx"Manufacturer=\"Example &lt;Apps&gt; &amp; Co[.]\"" escaped-source
                    "the human-readable publisher must be XML-escaped")
(check-false (regexp-match? #rx"Manufacturer=\"dev[.]rivet[.]smoke-test\"" escaped-source)
             "the reverse-DNS identifier must not leak into ARP Publisher")
(check-regexp-match #rx"Key=\"Software\\\\dev\\.rivet\\.smoke-test\\\\Shortcuts\"" escaped-source)

;; Shortcut authoring coexists with URL scheme / file association registration.
(define registration-source
  (wix-source-for (hasheq 'url-schemes '("smoke")
                          'file-associations
                          (list (hasheq 'extension ".smk"
                                        'description "Smoke Document")))))
(check-equal? (length (regexp-match* #rx"<Shortcut Id=" registration-source)) 2
              "shortcuts must survive registration authoring")
(check-regexp-match #rx"NativeActivationRegistration" registration-source)

;; Add/Remove Programs pinning rides on the configured windows icon.
(check-false (regexp-match? #rx"ARPPRODUCTICON" plain-source)
             "projects without a windows icon must not pin an ARP icon")

;; The wizard UI is unconditional: every MSI gets the standard install-dir
;; sequence with a launch checkbox on the finish page.
(check-regexp-match #rx"<ui:WixUI Id=\"WixUI_InstallDir\" />" plain-source
                    "the MSI must author the install-dir wizard sequence through the UI extension")
(check-regexp-match #rx"xmlns:ui=\"http://wixtoolset.org/schemas/v4/wxs/ui\"" plain-source)
(check-regexp-match #rx"<Property Id=\"WIXUI_INSTALLDIR\" Value=\"INSTALLFOLDER\" />" plain-source
                    "the wizard must target the real install folder")
(check-regexp-match #rx"<Property Id=\"WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT\" Value=\"Launch Smoke\" />" plain-source
                    "the finish page must offer launching the app")
(check-regexp-match
 #rx"<Property Id=\"WixShellExecTarget\" Value=\"\\[INSTALLFOLDER\\]RivetHost.exe\" />"
 plain-source)
(check-regexp-match
 #rx"<CustomAction Id=\"LaunchApplication\" BinaryRef=\"Wix4UtilCA_(X64|ARM64)\" DllEntry=\"WixShellExec\" Impersonate=\"yes\" />"
 plain-source
 "the launch action must come from the architecture-appropriate Util CA")
(check-regexp-match
 #rx"<Publish Dialog=\"ExitDialog\" Control=\"Finish\" Event=\"DoAction\" Value=\"LaunchApplication\" Condition=\"WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 and NOT Installed\" Order=\"2\" />"
 plain-source
 "the checkbox must launch only on a fresh install")
(check-regexp-match #rx"<WixVariable Id=\"WixUILicenseRtf\" Value=\"[^\"]+license[.]rtf\" />"
                    plain-source
                    "the license page always resolves to an RTF")
(check-false (regexp-match? #rx"WixUIBannerBmp|WixUIDialogBmp" plain-source)
             "wizard bitmaps stay unauthored unless the project configures them")

;; A repository LICENSE renders into the wizard RTF, ASCII-safe with RTF
;; paragraph breaks and unicode escapes.
(void
 (call-with-output-file (build-path package-root "LICENSE")
   #:exists 'truncate/replace
   (lambda (out) (display "Smoke License\nsecond line with ünïcode ✓\n" out))))
(void (wix-source-for (hasheq)))
(define generated-rtf
  (file->string (build-path package-root ".rivet" "installer" "license.rtf")))
(check-regexp-match #rx"^\\{\\\\rtf1\\\\ansi" generated-rtf
                    "the generated license must be RTF")
(check-regexp-match #rx"Smoke License\\\\par" generated-rtf
                    "license line breaks must become RTF paragraph breaks")
(check-regexp-match #rx"\\\\u252\\?" generated-rtf
                    "non-ASCII license characters must become unicode escapes")
(check-false (regexp-match? #rx"ünïcode" generated-rtf)
             "the generated RTF must stay ASCII so WiX never re-decodes it")
(delete-file (build-path package-root "LICENSE"))

;; A configured RTF replaces the generated one verbatim.
(define license-page (build-path package-root "branding" "license-page.rtf"))
(make-parent-directory* license-page)
(void
 (call-with-output-file license-page #:exists 'truncate/replace
   (lambda (out) (display "{\\rtf1\\ansi configured license page}" out))))
(define configured-license-source
  (wix-source-for (hasheq 'windows-license "branding/license-page.rtf")))
(check-regexp-match #rx"<WixVariable Id=\"WixUILicenseRtf\" Value=\"[^\"]*license-page[.]rtf\" />"
                    configured-license-source
                    "a configured license page must win over the generated one")

;; Wizard bitmaps ride in through WixVariables when configured. The fixtures
;; are real 24bpp BMPs at the exact wizard sizes (the binder validates them).
(define (minimal-bmp width height fill)
  (define row-size (* 4 (ceiling (/ (* width 24) 32))))
  (define pixel-size (* row-size height))
  (define (u16-le n)
    (bytes (bitwise-and n #xFF) (bitwise-and (arithmetic-shift n -8) #xFF)))
  (define (u32-le n)
    (bytes (bitwise-and n #xFF) (bitwise-and (arithmetic-shift n -8) #xFF)
           (bitwise-and (arithmetic-shift n -16) #xFF)
           (bitwise-and (arithmetic-shift n -24) #xFF)))
  (bytes-append #"BM"
                (u32-le (+ 14 40 pixel-size)) (u16-le 0) (u16-le 0) (u32-le 54)
                (u32-le 40) (u32-le width) (u32-le height)
                (u16-le 1) (u16-le 24) (u32-le 0) (u32-le pixel-size)
                (u32-le 2835) (u32-le 2835) (u32-le 0) (u32-le 0)
                (make-bytes pixel-size fill)))
(define banner-file (build-path package-root "branding" "wizard-banner.bmp"))
(define dialog-file (build-path package-root "branding" "wizard-dialog.bmp"))
(void
 (call-with-output-file banner-file #:exists 'truncate/replace
   (lambda (out) (write-bytes (minimal-bmp 493 58 #xC8) out)))
 (call-with-output-file dialog-file #:exists 'truncate/replace
   (lambda (out) (write-bytes (minimal-bmp 493 312 #xC8) out))))
(define bitmap-source
  (wix-source-for (hasheq 'windows-installer-bitmaps
                          (hasheq 'banner "branding/wizard-banner.bmp"
                                  'dialog "branding/wizard-dialog.bmp"))))
(check-regexp-match #rx"<WixVariable Id=\"WixUIBannerBmp\" Value=\"[^\"]*wizard-banner[.]bmp\" />"
                    bitmap-source)
(check-regexp-match #rx"<WixVariable Id=\"WixUIDialogBmp\" Value=\"[^\"]*wizard-dialog[.]bmp\" />"
                    bitmap-source)

;; A minimal but structurally valid 16x16 32bpp ICO (WiX's binder parses the
;; icon when embedding it, so the fixture has to be the real format).
(define (minimal-16x16-ico)
  (define (u16-le n)
    (bytes (bitwise-and n #xFF) (bitwise-and (arithmetic-shift n -8) #xFF)))
  (define (u32-le n)
    (bytes (bitwise-and n #xFF) (bitwise-and (arithmetic-shift n -8) #xFF)
           (bitwise-and (arithmetic-shift n -16) #xFF)
           (bitwise-and (arithmetic-shift n -24) #xFF)))
  (define xor-bytes (make-bytes (* 16 16 4) #xCC))
  (define and-mask (make-bytes (* 16 4) 0))
  (define header
    (bytes-append (u32-le 40)          ; biSize
                  (u32-le 16)          ; biWidth
                  (u32-le 32)          ; biHeight (XOR + AND height)
                  (u16-le 1)           ; biPlanes
                  (u16-le 32)          ; biBitCount
                  (u32-le 0)           ; biCompression: BI_RGB
                  (u32-le (bytes-length xor-bytes))
                  (u32-le 0) (u32-le 0) (u32-le 0) (u32-le 0)))
  (define image-bytes (bytes-append header xor-bytes and-mask))
  (bytes-append (u16-le 0)            ; reserved
                (u16-le 1)            ; type: icon
                (u16-le 1)            ; image count
                (bytes 16 16 0 0)     ; entry: 16x16, no palette
                (u16-le 1) (u16-le 32)
                (u32-le (bytes-length image-bytes))
                (u32-le 22)           ; offset: 6-byte dir + 16-byte entry
                image-bytes))
(define icon-file (build-path package-root "shared" "assets" "app.ico"))
(make-parent-directory* icon-file)
(call-with-output-file icon-file #:exists 'truncate/replace
  (lambda (out) (write-bytes (minimal-16x16-ico) out)))
(define icon-source
  (wix-source-for (hasheq 'windows-icon "shared/assets/app.ico")))
(check-regexp-match
 #rx"<Icon Id=\"RivetAppIcon[.]ico\" SourceFile=\"[^\"]*app[.]ico\" />"
 icon-source
 "a configured windows icon must be embedded into the MSI")
(check-regexp-match
 #rx"<Property Id=\"ARPPRODUCTICON\" Value=\"RivetAppIcon[.]ico\" />"
 icon-source
 "the pinned ARP icon must reference the embedded icon")

;; ---------------------------------------------------------------------------
;; Real MSI build (Windows hosts only: the WiX 5 binder needs the Windows
;; Installer API for the final database, and its Directory-name validation
;; rejects every value on POSIX hosts; release CI builds MSIs on Windows)

(define wix (or (find-executable-path "wix") (find-executable-path "wix.exe")))
(define (build-smoke-msi! overrides msi-name)
  (define project
    (rivet-project package-root (hash-union (hasheq 'name "Smoke") overrides)))
  (define source (build-path package-root ".rivet" "installer" "product.wxs"))
  (write-wix-source! project package source)
  (define msi (build-path package-root msi-name))
  (define exit-code
    (parameterize ([current-directory package-root])
      (system*/exit-code wix "build" "-arch" "x64"
                         "-ext" "WixToolset.UI.wixext"
                         "-ext" "WixToolset.Util.wixext"
                         "-o" (path->string msi) (path->string source))))
  (check-equal? exit-code 0 "wix must accept the generated source")
  (when (file-exists? msi)
    (define size (file-size msi))
    (check-true (> size 1024) "the built MSI must not be empty")
    (delete-file msi)))

(when (and wix (equal? 'windows (system-type 'os)))
  (ensure-wix-extensions! 'build-smoke wix)
  (build-smoke-msi! (hasheq) "Smoke-plain-windows-x64.msi")
  ;; the icon variant validates the ARP-icon fragment against the real schema
  (build-smoke-msi! (hasheq 'windows-icon "shared/assets/app.ico")
                    "Smoke-icon-windows-x64.msi")
  ;; the branded variant validates wizard bitmaps and the configured license
  (build-smoke-msi! (hasheq 'windows-installer-bitmaps
                            (hasheq 'banner "branding/wizard-banner.bmp"
                                    'dialog "branding/wizard-dialog.bmp")
                            'windows-license "branding/license-page.rtf")
                    "Smoke-branded-windows-x64.msi"))

(delete-directory/files package-root)
