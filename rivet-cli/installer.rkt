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
  (define schemes (project-url-schemes project))
  (define associations (project-file-associations project))
  (define registrations? (or (pair? schemes) (pair? associations)))
  (call-with-output-file source
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Wix xmlns=\"http://wixtoolset.org/schemas/v4/wxs\">\n  <Package Name=\"~a\" Manufacturer=\"~a\" Version=\"~a\" UpgradeCode=\"~a\" Scope=\"perMachine\">\n    <MajorUpgrade DowngradeErrorMessage=\"A newer version is already installed.\" />\n    <MediaTemplate EmbedCab=\"yes\" />\n    <Feature Id=\"Main\"><ComponentGroupRef Id=\"ProductComponents\" /></Feature>\n  </Package>\n  <Fragment><StandardDirectory Id=\"ProgramFiles6432Folder\"><Directory Id=\"INSTALLFOLDER\" Name=\"~a\" /></StandardDirectory></Fragment>\n  <Fragment><ComponentGroup Id=\"ProductComponents\" Directory=\"INSTALLFOLDER\">\n"
               (xml-escape (project-display-name project))
               (xml-escape identifier)
               (xml-escape (project-version project))
               "6B7D0F2E-8B9D-4FB5-9F69-1B12E50F60C1"
               (xml-escape name))
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
