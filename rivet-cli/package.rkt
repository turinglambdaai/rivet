#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         "build.rkt"
         "linux-package.rkt"
         "project.rkt"
         "signing-options.rkt"
         "verify.rkt"
         "windows-tools.rkt")

(provide package-project!
         sign-windows-production!)

(define (run! who executable . args)
  (unless executable
    (error who "required executable was not found"))
  (unless (apply system* executable args)
    (raise-arguments-error who
                           "external command failed"
                           "executable" executable
                           "arguments" args)))

;; Use for commands whose argv may contain secrets. In particular, signtool's
;; PFX mode receives the certificate password through `/p`. Never include that
;; argv in an exception or diagnostic string.
(define (run-sensitive! who executable description args)
  (unless executable
    (error who "required executable was not found"))
  (unless (apply system* executable args)
    (error who "~a failed; sensitive command arguments were intentionally omitted"
           description)))

(define (remove-path! path)
  (cond
    [(directory-exists? path) (delete-directory/files path)]
    [(file-exists? path) (delete-file path)]))

(define (copy-tree! source destination)
  (remove-path! destination)
  (copy-directory/files source destination))

(define (copy-macos-bundle! source destination)
  (remove-path! destination)
  (define ditto (find-executable-path "ditto"))
  (run! 'package-project!
        ditto
        (path->string source)
        (path->string destination)))

(define (write-macos-info! path
                           display-name
                           executable
                           identifier
                           version
                           build
                           minimum-version
                           icon-name
                           url-schemes
                           file-associations)
  (define (xml-escape value)
    (regexp-replace*
     #px"[&<>\"]" value
     (lambda (match)
       (case (string-ref match 0)
         [(#\&) "&amp;"] [(#\<) "&lt;"] [(#\>) "&gt;"] [else "&quot;"]))))
  (define url-fragment
    (if (null? url-schemes)
        ""
        (format
         "  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>~a</string><key>CFBundleURLSchemes</key><array>~a</array></dict></array>\n"
         (xml-escape identifier)
         (apply string-append
                (for/list ([scheme (in-list url-schemes)])
                  (format "<string>~a</string>" (xml-escape scheme)))))))
  (define association-fragment
    (if (null? file-associations)
        ""
        (format
         "  <key>CFBundleDocumentTypes</key><array>~a</array>\n"
         (apply string-append
                (for/list ([association (in-list file-associations)])
                  (define extension (substring (hash-ref association 'extension) 1))
                  (define description
                    (hash-ref association 'description
                              (lambda () (string-append display-name " Document"))))
                  (format "<dict><key>CFBundleTypeName</key><string>~a</string><key>CFBundleTypeExtensions</key><array><string>~a</string></array><key>CFBundleTypeRole</key><string>Editor</string></dict>"
                          (xml-escape description)
                          (xml-escape extension)))))))
  (define icon-fragment
    (if icon-name
        (format "  <key>CFBundleIconFile</key><string>~a</string>\n"
                (xml-escape icon-name))
        ""))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>CFBundleDevelopmentRegion</key><string>en</string>\n  <key>CFBundleExecutable</key><string>~a</string>\n  <key>CFBundleIdentifier</key><string>~a</string>\n  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n  <key>CFBundleName</key><string>~a</string>\n  <key>CFBundleDisplayName</key><string>~a</string>\n  <key>CFBundlePackageType</key><string>APPL</string>\n  <key>CFBundleShortVersionString</key><string>~a</string>\n  <key>CFBundleVersion</key><string>~a</string>\n  <key>LSMinimumSystemVersion</key><string>~a</string>\n~a~a~a  <key>NSHighResolutionCapable</key><true/>\n</dict>\n</plist>\n"
               (xml-escape executable)
               (xml-escape identifier)
               (xml-escape display-name)
               (xml-escape display-name)
               (xml-escape version)
               (xml-escape (format "~a" build))
               (xml-escape minimum-version)
               icon-fragment
               url-fragment
               association-fragment))))

(define (write-entitlements! path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (display
       "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>\n</dict></plist>\n"
       out))))

(define (sign-windows-production! executable settings)
  (define tools (discover-windows-toolchain))
  (define signtool (windows-toolchain-signtool tools))
  (unless signtool
    (error 'package-project!
           "signtool.exe was not found; install the Windows SDK before production packaging"))

  (define identity-args
    (cond
      [(windows-signing-certificate-sha1 settings)
       (list "/sha1" (windows-signing-certificate-sha1 settings))]
      [else
       (define pfx (string->path (windows-signing-pfx settings)))
       (unless (file-exists? pfx)
         (raise-arguments-error 'package-project!
                                "configured Windows signing PFX does not exist"
                                "RIVET_WINDOWS_SIGN_PFX" pfx))
       (list "/f" (path->string pfx)
             "/p" (windows-signing-pfx-password settings))]))

  (define args
    (append
     (list "sign" "/fd" "SHA256")
     identity-args
     (list "/tr" (windows-signing-timestamp-url settings)
           "/td" "SHA256"
           (path->string executable))))
  (run-sensitive! 'package-project!
                  signtool
                  "Windows Authenticode signing"
                  args))

(define (package-windows! project stage name production?)
  (define architecture
    (case (system-type 'arch)
      [(aarch64 arm64) "arm64"]
      [else "x64"]))
  (define destination
    (project-path project "dist" (string-append name "-windows-" architecture)))
  (make-directory* (path-only destination))
  (copy-tree! stage destination)
  (when production?
    (define settings (load-windows-production-signing))
    ;; Sign Rivet's application executable. Bundled Windows App SDK/Racket DLLs
    ;; remain byte-for-byte upstream artifacts instead of being re-signed.
    (sign-windows-production! (build-path destination "RivetHost.exe") settings))
  destination)

(define (package-linux! project stage name)
  (define destination
    (project-path project "dist" (linux-package-directory-name project)))
  (make-directory* (path-only destination))
  (copy-tree! stage destination)
  (file-or-directory-permissions (build-path destination "RivetHost") #o755)
  destination)

(define (sign-macos! codesign identity entitlements racket-framework app production?)
  ;; Hardened runtime (`--options runtime`) is for production distribution:
  ;; with an ad-hoc development signature, its library validation rejects
  ;; the embedded ad-hoc Racket dylib at launch with a misleading
  ;; "different Team IDs" AMFI error.
  (define common
    (append
     (list "--force" "--sign" identity)
     (if production? (list "--options" "runtime" "--timestamp") '())))
  ;; Sign nested code first, then the outer app. Signing the framework
  ;; bundle alone leaves the inner dylib's stale signature (it was modified
  ;; by install_name_tool during staging), so the inner Mach-O is signed
  ;; explicitly before the wrapper.
  (define inner-dylib
    (for/first ([version (in-list (sort
                                   (map path->string
                                        (directory-list
                                         (build-path racket-framework "Versions")))
                                   string<?))]
                #:when (regexp-match? #rx"_CS$" version))
      (build-path racket-framework "Versions" version "Racket")))
  (when inner-dylib
    (apply run!
           'package-project!
           codesign
           (append common (list (path->string inner-dylib)))))
  (apply run!
         'package-project!
         codesign
         (append common (list (path->string racket-framework))))
  (apply run!
         'package-project!
         codesign
         (append common
                 (list "--entitlements" (path->string entitlements)
                       (path->string app)))))

(define (notarize-macos! project app name notary-profile)
  (define xcrun (find-executable-path "xcrun"))
  (define ditto (find-executable-path "ditto"))
  (unless xcrun
    (error 'package-project! "xcrun was not found; install Xcode command line tools"))
  (unless ditto
    (error 'package-project! "ditto was not found"))

  (define notary-dir (project-path project ".rivet" "notary"))
  (make-directory* notary-dir)
  (define archive (build-path notary-dir (string-append name ".zip")))
  (remove-path! archive)
  (run! 'package-project!
        ditto
        "-c" "-k" "--keepParent"
        (path->string app)
        (path->string archive))
  (run! 'package-project!
        xcrun
        "notarytool" "submit"
        (path->string archive)
        "--keychain-profile" notary-profile
        "--wait")
  (run! 'package-project!
        xcrun
        "stapler" "staple"
        (path->string app)))

;; SwiftPM resource bundles (RivetHost_*.bundle) staged beside the built
;; executable by build-macos!. Detect them at the .app assembly boundary:
;; Bundle.module resolves them relative to Bundle.main.bundleURL (the .app
;; root next to Contents/), which codesign rejects as unsealed content.
(define (staged-swiftpm-bundles stage)
  (for/list ([entry (in-list (directory-list stage))]
             #:when (regexp-match? #rx"[.]bundle$" (path->string entry)))
    (path->string entry)))

(define (package-macos! project stage name production?)
  (define dist (project-path project "dist"))
  (make-directory* dist)
  (define app (build-path dist (string-append name ".app")))
  (remove-path! app)

  (define contents (build-path app "Contents"))
  (define macos (build-path contents "MacOS"))
  (define frameworks (build-path contents "Frameworks"))
  (define resources (build-path contents "Resources"))
  (make-directory* macos)
  (make-directory* frameworks)
  (make-directory* resources)

  (define executable-name name)
  (define display-name (project-display-name project))
  (define version (project-version project))
  (define build (project-build project))
  (define identifier (project-identifier project))

  (define source-executable (build-path stage "RivetHost"))
  (define target-executable (build-path macos executable-name))
  (copy-file source-executable target-executable #t)
  (file-or-directory-permissions target-executable #o755)

  ;; Keep non-code runtime assets in Contents/Resources. Putting boot files in
  ;; Contents/MacOS makes codesign classify them as nested executable code.
  (copy-tree! (build-path stage "res") (build-path resources "res"))
  (copy-tree! (build-path stage "runtime") (build-path resources "runtime"))
  (define staged-app-resources (build-path stage "app"))
  (when (directory-exists? staged-app-resources)
    (copy-tree! staged-app-resources (build-path resources "app")))

  (define configured-icon
    (required-project-icon project (project-macos-icon project) 'macos))
  (define packaged-icon-name (and configured-icon "AppIcon.icns"))
  (when configured-icon
    (copy-file configured-icon
               (build-path resources packaged-icon-name)
               #t))

  (define racket-framework (build-path frameworks "Racket.framework"))
  (copy-macos-bundle! (build-path stage "Frameworks" "Racket.framework")
                      racket-framework)

  ;; SwiftPM resource bundles are looked up by Bundle.module at the .app root
  ;; next to Contents/, which codesign rejects ("unsealed contents present in
  ;; the bundle root") and nested signing cannot fix because the generated
  ;; bundle is not a codesignable bundle. Fail closed instead of producing an
  ;; app that cannot be signed: declare shared data in rivet.rktd `resources`
  ;; (staged under Contents/Resources/app, sealable and cross-platform) and
  ;; read it in native code from that location. See the resources section in
  ;; docs/configuration.md.
  (define swiftpm-bundles (staged-swiftpm-bundles stage))
  (unless (null? swiftpm-bundles)
    (error 'package-project!
           (string-append
            "the macOS host's Swift package declares SwiftPM resources (~a); "
            "SwiftPM resource bundles cannot ship inside a signed app bundle. "
            "Move the data to the `resources` declaration in rivet.rktd and "
            "read it from Contents/Resources/app in native code — see "
            "docs/configuration.md, \"Application resources and icons\".")
      (string-join swiftpm-bundles ", ")))

  (write-macos-info! (build-path contents "Info.plist")
                     display-name
                     executable-name
                     identifier
                     version
                     build
                     (project-macos-min-version project)
                     packaged-icon-name
                     (project-url-schemes project)
                     (project-file-associations project))

  (define entitlements
    (project-path project ".rivet" "macos-entitlements.plist"))
  (make-parent-directory* entitlements)
  (write-entitlements! entitlements)

  (define codesign (find-executable-path "codesign"))
  (unless codesign
    (error 'package-project! "codesign was not found"))

  (cond
    [production?
     (define settings (load-macos-production-signing))
     (sign-macos! codesign
                  (macos-signing-identity settings)
                  entitlements
                  racket-framework
                  app
                  #t)
     (notarize-macos! project
                       app
                       name
                       (macos-signing-notary-profile settings))]
    [else
     (sign-macos! codesign "-" entitlements racket-framework app #f)])
  app)

(define (package-project! project
                          #:production? [production? #f]
                          #:launch-smoke? [launch-smoke? #t])
  (when (and production? (eq? (system-type 'os) 'unix))
    (error 'package-project!
           "Linux production releases are produced by `raco rivet release`, which signs the self-contained installer; `package --production` targets Windows and macOS"))
  (define executable
    (build-project! project
                    #:configuration "Release"
                    #:self-contained? #t))
  (define stage (path-only executable))
  (define name (project-name project))

  (define packaged
    (case (system-type 'os)
      [(windows) (package-windows! project stage name production?)]
      [(macosx) (package-macos! project stage name production?)]
      [(unix) (package-linux! project stage name)]
      [else
       (error 'package-project!
              "Rivet packages currently target Windows, macOS, and Linux")]))

  ;; `package` should never report success for an artifact that still depends
  ;; on the developer machine. Production mode additionally verifies the
  ;; platform trust/notarization result.
  (verify-package! project packaged
                   #:production? production?
                   #:launch-smoke? launch-smoke?)
  packaged)

(module+ test-support
  (provide staged-swiftpm-bundles
           write-macos-info!))
