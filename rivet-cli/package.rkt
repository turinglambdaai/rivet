#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         "build.rkt"
         "project.rkt")

(provide package-project!)

(define (run! who executable . args)
  (unless executable
    (error who "required executable was not found"))
  (unless (apply system* executable args)
    (raise-arguments-error who
                           "external command failed"
                           "executable" executable
                           "arguments" args)))

(define (remove-path! path)
  (cond
    [(directory-exists? path) (delete-directory/files path)]
    [(file-exists? path) (delete-file path)]))

(define (copy-tree! source destination)
  (remove-path! destination)
  (copy-directory/files source destination))

(define (macos-identifier name)
  (string-append
   "dev.rivet."
   (regexp-replace* #px"[^a-z0-9.-]"
                    (string-downcase name)
                    "-")))

(define (write-macos-info! path name executable)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>CFBundleDevelopmentRegion</key><string>en</string>\n  <key>CFBundleExecutable</key><string>~a</string>\n  <key>CFBundleIdentifier</key><string>~a</string>\n  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n  <key>CFBundleName</key><string>~a</string>\n  <key>CFBundlePackageType</key><string>APPL</string>\n  <key>CFBundleShortVersionString</key><string>0.1.0</string>\n  <key>CFBundleVersion</key><string>1</string>\n  <key>LSMinimumSystemVersion</key><string>14.0</string>\n  <key>NSHighResolutionCapable</key><true/>\n</dict>\n</plist>\n"
               executable
               (macos-identifier name)
               name))))

(define (write-entitlements! path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (display
       "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>\n</dict></plist>\n"
       out))))

(define (package-windows! project stage name)
  (define destination
    (project-path project "dist" (string-append name "-windows-x64")))
  (make-directory* (path-only destination))
  (copy-tree! stage destination)
  destination)

(define (package-macos! project stage name)
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
  (define source-executable (build-path stage "RivetHost"))
  (define target-executable (build-path macos executable-name))
  (copy-file source-executable target-executable #t)
  (file-or-directory-permissions target-executable #o755)

  ;; Keep res/runtime beside the executable because both generated hosts use
  ;; executable-relative lookup. Frameworks follow normal .app conventions.
  (copy-tree! (build-path stage "res") (build-path macos "res"))
  (copy-tree! (build-path stage "runtime") (build-path macos "runtime"))
  (copy-tree! (build-path stage "Frameworks" "Racket.framework")
              (build-path frameworks "Racket.framework"))

  (write-macos-info! (build-path contents "Info.plist") name executable-name)

  (define entitlements
    (project-path project ".rivet" "macos-entitlements.plist"))
  (make-parent-directory* entitlements)
  (write-entitlements! entitlements)

  (define codesign (find-executable-path "codesign"))
  (when codesign
    (run! 'package-project!
          codesign
          "--force"
          "--deep"
          "--sign" "-"
          "--options" "runtime"
          "--entitlements" (path->string entitlements)
          (path->string app)))
  app)

(define (package-project! project)
  (define executable
    (build-project! project
                    #:configuration "Release"
                    #:self-contained? #t))
  (define stage (path-only executable))
  (define name (project-ref project 'name))

  (case (system-type 'os)
    [(windows) (package-windows! project stage name)]
    [(macosx) (package-macos! project stage name)]
    [else
     (error 'package-project!
            "Rivet packages currently target Windows and macOS")]))
