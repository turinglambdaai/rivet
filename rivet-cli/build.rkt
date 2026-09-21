#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         racket/system
         "codegen.rkt"
         "project.rkt"
         "runtime.rkt"
         "windows-tools.rkt")

(provide build-project!
         dev-project!)

(define-runtime-path rivet-root "..")

(define (run! who executable . args)
  (unless executable
    (error who "required executable was not found"))
  (unless (apply system* executable args)
    (raise-arguments-error who
                           "external command failed"
                           "executable" executable
                           "arguments" args)))

(define (fresh-directory! path)
  (when (directory-exists? path)
    (delete-directory/files path))
  (make-directory* path))

(define (copy-required! who source destination)
  (unless (file-exists? source)
    (raise-arguments-error who "required source file does not exist"
                           "source" source))
  (make-parent-directory* destination)
  (copy-file source destination #t))

(define (compile-backend! project runtime stage)
  (define backend-relative (project-ref project 'backend))
  (define backend (project-path project backend-relative))
  (unless (file-exists? backend)
    (raise-arguments-error 'build-project!
                           "configured backend module does not exist"
                           "backend" backend))

  (define res-dir (build-path stage "res"))
  (define runtime-dir (build-path stage "runtime"))
  (make-directory* res-dir)
  (make-directory* runtime-dir)

  (define core (build-path res-dir "core.zo"))
  (define raco (find-executable-path "raco"))
  (run! 'build-project!
        raco
        "ctool"
        "--runtime" (path->string runtime-dir)
        "--runtime-access" "runtime"
        "--mods" (path->string core)
        (path->string backend))

  (for ([source (in-list
                 (list (racket-runtime-petite-boot runtime)
                       (racket-runtime-scheme-boot runtime)
                       (racket-runtime-racket-boot runtime)))])
    (copy-required! 'build-project!
                    source
                    (build-path runtime-dir (file-name-from-path source))))
  core)

(define (prepare-windows-import-library! project runtime lib-exe)
  (unless lib-exe
    (error 'build-project!
           "MSVC lib.exe was not found; install Visual Studio Build Tools with the Desktop development with C++ workload"))

  (define build-dir (project-path project ".rivet" "build" "windows"))
  (make-directory* build-dir)
  (define output (build-path build-dir "libracketcs.lib"))
  (define def (racket-runtime-racketcs-def runtime))

  (run! 'build-project!
        lib-exe
        (string-append "/def:" (path->string def))
        (string-append "/out:" (path->string output))
        "/machine:x64")
  output)

(define (with-windows-build-environment runtime import-lib thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (define (set-path! key path)
    (environment-variables-set! env key (path->bytes path)))
  (set-path! #"RIVET_ROOT" (simplify-path rivet-root #t))
  (set-path! #"RIVET_RACKET_INCLUDE" (racket-runtime-include-dir runtime))
  (set-path! #"RIVET_RACKET_IMPORT_LIB" import-lib)
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (build-windows! project runtime stage configuration self-contained?)
  (unless (eq? (system-type 'arch) 'x86_64)
    (error 'build-project!
           "the first Windows milestone supports x64 only; ARM64 support is planned"))

  (define host-project (project-path project "windows" "RivetHost.vcxproj"))
  (unless (file-exists? host-project)
    (raise-arguments-error 'build-project!
                           "Windows host project is missing"
                           "expected" host-project))

  (define toolchain (discover-windows-toolchain))
  (define import-lib
    (prepare-windows-import-library!
     project runtime (windows-toolchain-lib toolchain)))
  (define racketcs-dll (racket-runtime-racketcs-dll runtime))
  (copy-required! 'build-project!
                  racketcs-dll
                  (build-path stage (file-name-from-path racketcs-dll)))

  (define msbuild (windows-toolchain-msbuild toolchain))
  (unless msbuild
    (error 'build-project!
           "MSBuild.exe was not found; install Visual Studio Build Tools with C++/WinUI support"))

  (define out-dir (path->string stage))
  (with-windows-build-environment
   runtime import-lib
   (lambda ()
     (run! 'build-project!
           msbuild
           (path->string host-project)
           "/restore"
           "/m"
           (string-append "/p:Configuration=" configuration)
           "/p:Platform=x64"
           (string-append "/p:RivetSelfContained="
                          (if self-contained? "true" "false"))
           (string-append "/p:OutDir=" out-dir))))
  (build-path stage "RivetHost.exe"))

(define (with-macos-build-environment framework-dir thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set!
   env #"RIVET_ROOT" (path->bytes (simplify-path rivet-root #t)))
  (environment-variables-set!
   env #"RIVET_RACKET_FRAMEWORK_DIR" (path->bytes framework-dir))
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (find-built-macos-executable build-dir)
  (define candidates
    (find-files
     (lambda (p)
       (and (file-exists? p)
            (let ([name (file-name-from-path p)])
              (and name (string=? (path->string name) "RivetHost")))))
     build-dir))
  (or (for/first ([p (in-list candidates)]
                  #:when (regexp-match? #rx"/(debug|release)/RivetHost$"
                                        (path->string p)))
        p)
      (and (pair? candidates) (car candidates))
      (error 'build-project! "Swift build completed but RivetHost was not found")))

(define (framework-version-string version-name)
  (regexp-replace #rx"_CS$" version-name ""))

(define (write-framework-info! version-dir version-name)
  (define resources-dir (build-path version-dir "Resources"))
  (make-directory* resources-dir)
  (define version (framework-version-string version-name))
  (call-with-output-file (build-path resources-dir "Info.plist")
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>CFBundleDevelopmentRegion</key><string>en</string>\n  <key>CFBundleExecutable</key><string>Racket</string>\n  <key>CFBundleIdentifier</key><string>org.racket-lang.Racket</string>\n  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n  <key>CFBundleName</key><string>Racket</string>\n  <key>CFBundlePackageType</key><string>FMWK</string>\n  <key>CFBundleShortVersionString</key><string>~a</string>\n  <key>CFBundleVersion</key><string>~a</string>\n</dict>\n</plist>\n"
               version
               version))))

(define (prepare-macos-framework! runtime stage)
  (define source (racket-runtime-racket-framework runtime))
  (unless source
    (error 'build-project! "the installed Racket CS does not provide Racket.framework"))

  (define frameworks-dir (build-path stage "Frameworks"))
  (define destination (build-path frameworks-dir "Racket.framework"))
  (make-directory* frameworks-dir)

  ;; Preserve the framework's versioned layout and any installer-provided links.
  (define ditto (find-executable-path "ditto"))
  (run! 'build-project! ditto (path->string source) (path->string destination))

  (define versions-dir (build-path destination "Versions"))
  (define version-dirs
    (sort
     (for/list ([entry (in-list (directory-list versions-dir))]
                #:do [(define name (path->string entry))
                      (define full (build-path versions-dir entry))]
                #:when (and (not (string=? name "Current"))
                            (directory-exists? full)
                            (file-exists? (build-path full "Racket"))))
       full)
     string<?
     #:key path->string))
  (define version-dir
    (or (for/first ([candidate (in-list version-dirs)]
                    #:when (regexp-match? #rx"_CS$"
                                          (path->string (file-name-from-path candidate))))
          candidate)
        (and (pair? version-dirs) (car version-dirs))
        (error 'build-project!
               "Racket.framework contains no usable version directory")))
  (define version-name (path->string (file-name-from-path version-dir)))

  ;; Turn the installer payload into a conventional framework bundle. Besides
  ;; helping ld discover it, the plist and symlinks are required for codesign to
  ;; recognize the nested framework inside the final .app.
  (write-framework-info! version-dir version-name)
  (define ln (find-executable-path "ln"))
  (run! 'build-project! ln "-sfn" version-name
        (path->string (build-path versions-dir "Current")))
  (run! 'build-project! ln "-sfn" "Versions/Current/Racket"
        (path->string (build-path destination "Racket")))
  (run! 'build-project! ln "-sfn" "Versions/Current/Resources"
        (path->string (build-path destination "Resources")))

  ;; Make the linked executable refer to the bundled framework through rpath
  ;; instead of the Racket installation path.
  (define install-name-tool (find-executable-path "install_name_tool"))
  (run! 'build-project!
        install-name-tool
        "-id"
        (format "@rpath/Racket.framework/Versions/~a/Racket" version-name)
        (path->string (build-path version-dir "Racket")))

  frameworks-dir)

(define (build-macos! project runtime stage configuration)
  (define swift (find-executable-path "swift"))
  (unless swift
    (error 'build-project! "swift was not found; install Xcode command line tools"))

  (define framework-dir (prepare-macos-framework! runtime stage))

  (define host-dir (project-path project "macos-host"))
  (define package-file (build-path host-dir "Package.swift"))
  (unless (file-exists? package-file)
    (raise-arguments-error 'build-project!
                           "macOS host package is missing"
                           "expected" package-file))

  (define build-dir (project-path project ".rivet" "build" "macos"))
  (make-directory* build-dir)
  (define swift-configuration (string-downcase configuration))

  (with-macos-build-environment
   framework-dir
   (lambda ()
     (run! 'build-project!
           swift
           "build"
           "--package-path" (path->string host-dir)
           "--scratch-path" (path->string build-dir)
           "-c" swift-configuration
           "-Xcc" (string-append "-I" (path->string (racket-runtime-include-dir runtime)))
           "-Xlinker" "-rpath"
           "-Xlinker" "@executable_path/Frameworks"
           "-Xlinker" "-rpath"
           "-Xlinker" "@executable_path/../Frameworks")))

  (define built (find-built-macos-executable build-dir))
  (define staged-executable (build-path stage "RivetHost"))
  (copy-required! 'build-project! built staged-executable)
  (file-or-directory-permissions staged-executable #o755)
  staged-executable)

(define (build-project! project
                        #:configuration [configuration "Debug"]
                        #:self-contained? [self-contained? #f])
  (generate-clients! project)
  (define runtime (discover-racket-runtime))
  (define stage (project-path project ".rivet" "stage"))
  (fresh-directory! stage)
  (compile-backend! project runtime stage)

  (case (system-type 'os)
    [(windows)
     (build-windows! project runtime stage configuration self-contained?)]
    [(macosx)
     (build-macos! project runtime stage configuration)]
    [else
     (error 'build-project!
            "Rivet native hosts currently target Windows and macOS")]))

(define (dev-project! project)
  ;; Development should start the generated app on a clean machine, not fail
  ;; because a matching Windows App Runtime happens not to be installed.
  (define executable
    (build-project! project
                    #:configuration "Debug"
                    #:self-contained? #t))
  (case (system-type 'os)
    [(windows macosx)
     (parameterize ([current-directory (path-only executable)])
       (run! 'dev-project! executable))]
    [else
     (error 'dev-project! "development runner is not available on this platform")]))
