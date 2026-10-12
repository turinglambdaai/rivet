#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         rackunit
         "../rivet-cli/installer.rkt"
         "../rivet-cli/project.rkt"
         (submod "../rivet-cli/installer.rkt" test-support))

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
;; Real MSI build (only where WiX is installed; release CI covers this too)

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
                         "-o" (path->string msi) (path->string source))))
  (check-equal? exit-code 0 "wix must accept the generated source")
  (when (file-exists? msi)
    (define size (file-size msi))
    (check-true (> size 1024) "the built MSI must not be empty")
    (delete-file msi)))

(when wix
  (build-smoke-msi! (hasheq) "Smoke-plain-windows-x64.msi")
  ;; the icon variant validates the ARP-icon fragment against the real schema
  (build-smoke-msi! (hasheq 'windows-icon "shared/assets/app.ico")
                    "Smoke-icon-windows-x64.msi"))

(delete-directory/files package-root)
