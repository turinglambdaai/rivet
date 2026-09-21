#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         "build.rkt"
         "project.rkt"
         "signing-options.rkt"
         "verify.rkt"
         "windows-tools.rkt")

(provide package-project!)

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

(define (macos-identifier name)
  (string-append
   "dev.rivet."
   (regexp-replace* #px"[^a-z0-9.-]"
                    (string-downcase name)
                    "-")))

(define (project-setting project key default)
  (project-ref project key (lambda () default)))

(define (write-macos-info! path
                           display-name
                           executable
                           identifier
                           version
                           build
                           minimum-version)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>CFBundleDevelopmentRegion</key><string>en</string>\n  <key>CFBundleExecutable</key><string>~a</string>\n  <key>CFBundleIdentifier</key><string>~a</string>\n  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n  <key>CFBundleName</key><string>~a</string>\n  <key>CFBundleDisplayName</key><string>~a</string>\n  <key>CFBundlePackageType</key><string>APPL</string>\n  <key>CFBundleShortVersionString</key><string>~a</string>\n  <key>CFBundleVersion</key><string>~a</string>\n  <key>LSMinimumSystemVersion</key><string>~a</string>\n  <key>NSHighResolutionCapable</key><true/>\n</dict>\n</plist>\n"
               executable
               identifier
               display-name
               display-name
               version
               build
               minimum-version))))

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
  (define destination
    (project-path project "dist" (string-append name "-windows-x64")))
  (make-directory* (path-only destination))
  (copy-tree! stage destination)
  (when production?
    (define settings (load-windows-production-signing))
    ;; Sign Rivet's application executable. Bundled Windows App SDK/Racket DLLs
    ;; remain byte-for-byte upstream artifacts instead of being re-signed.
    (sign-windows-production! (build-path destination "RivetHost.exe") settings))
  destination)

(define (sign-macos! codesign identity entitlements racket-framework app production?)
  (define common
    (append
     (list "--force" "--sign" identity "--options" "runtime")
     (if production? (list "--timestamp") '())))
  ;; Sign nested code first, then the outer app. This is more deterministic
  ;; than asking --deep to infer the signing order.
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
  (define display-name (project-setting project 'display-name name))
  (define version (project-setting project 'version "0.1.0"))
  (define build (project-setting project 'build 1))
  (define identifier
    (project-setting project 'identifier (macos-identifier name)))

  (define source-executable (build-path stage "RivetHost"))
  (define target-executable (build-path macos executable-name))
  (copy-file source-executable target-executable #t)
  (file-or-directory-permissions target-executable #o755)

  ;; Keep non-code runtime assets in Contents/Resources. Putting boot files in
  ;; Contents/MacOS makes codesign classify them as nested executable code.
  (copy-tree! (build-path stage "res") (build-path resources "res"))
  (copy-tree! (build-path stage "runtime") (build-path resources "runtime"))

  (define racket-framework (build-path frameworks "Racket.framework"))
  (copy-macos-bundle! (build-path stage "Frameworks" "Racket.framework")
                      racket-framework)

  (write-macos-info! (build-path contents "Info.plist")
                     display-name
                     executable-name
                     identifier
                     version
                     build
                     (project-macos-min-version project))

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

(define (package-project! project #:production? [production? #f])
  (define executable
    (build-project! project
                    #:configuration "Release"
                    #:self-contained? #t))
  (define stage (path-only executable))
  (define name (project-ref project 'name))

  (define packaged
    (case (system-type 'os)
      [(windows) (package-windows! project stage name production?)]
      [(macosx) (package-macos! project stage name production?)]
      [else
       (error 'package-project!
              "Rivet packages currently target Windows and macOS")]))

  ;; `package` should never report success for an artifact that still depends
  ;; on the developer machine. Production mode additionally verifies the
  ;; platform trust/notarization result.
  (verify-package! project packaged #:production? production?)
  packaged)
