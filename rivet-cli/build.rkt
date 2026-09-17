#lang racket/base

(require racket/file
         racket/path
         racket/runtime-path
         racket/system
         "project.rkt"
         "runtime.rkt")

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

  ;; Boot images are part of the exact Racket runtime compatibility unit, not
  ;; generic files that Rivet downloads from a nearby release.
  (for ([source (in-list
                 (list (racket-runtime-petite-boot runtime)
                       (racket-runtime-scheme-boot runtime)
                       (racket-runtime-racket-boot runtime)))])
    (copy-required! 'build-project!
                    source
                    (build-path runtime-dir (file-name-from-path source))))
  core)

(define (prepare-windows-import-library! project runtime)
  (define lib-exe (find-executable-path "lib.exe"))
  (unless lib-exe
    (error 'build-project!
           "lib.exe was not found; install the Visual Studio C++ desktop workload or run from a Developer shell"))

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
  (set-path! #"RIVET_ROOT" (build-path (simplify-path rivet-root #t) ""))
  (set-path! #"RIVET_RACKET_INCLUDE" (racket-runtime-include-dir runtime))
  (set-path! #"RIVET_RACKET_IMPORT_LIB" import-lib)
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (build-windows! project runtime stage configuration)
  (unless (eq? (system-type 'arch) 'x86_64)
    (error 'build-project!
           "the first Windows milestone supports x64 only; ARM64 support is planned"))

  (define host-project (project-path project "windows" "RivetHost.vcxproj"))
  (unless (file-exists? host-project)
    (raise-arguments-error 'build-project!
                           "Windows host project is missing"
                           "expected" host-project))

  (define import-lib (prepare-windows-import-library! project runtime))
  (define racketcs-dll (racket-runtime-racketcs-dll runtime))
  (copy-required! 'build-project!
                  racketcs-dll
                  (build-path stage (file-name-from-path racketcs-dll)))

  (define msbuild (find-executable-path "MSBuild.exe"))
  (unless msbuild
    (error 'build-project!
           "MSBuild.exe was not found; install Visual Studio Build Tools with C++/WinUI support"))

  (define out-dir (path->string (build-path stage "")))
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
           (string-append "/p:OutDir=" out-dir))))
  (build-path stage "RivetHost.exe"))

(define (build-project! project #:configuration [configuration "Debug"])
  (define runtime (discover-racket-runtime))
  (define stage (project-path project ".rivet" "stage"))
  (fresh-directory! stage)
  (compile-backend! project runtime stage)

  (case (system-type 'os)
    [(windows)
     (build-windows! project runtime stage configuration)]
    [(macosx)
     ;; The Swift host is intentionally the next implementation slice. The
     ;; backend artifact is already complete and useful for protocol tests.
     (error 'build-project!
            "macOS native host wiring is not implemented yet")]
    [else
     (error 'build-project!
            "Rivet native hosts currently target Windows and macOS")]))

(define (dev-project! project)
  (define executable (build-project! project #:configuration "Debug"))
  (case (system-type 'os)
    [(windows)
     (run! 'dev-project! executable)]
    [else
     (error 'dev-project! "development runner is not available on this platform")]))
