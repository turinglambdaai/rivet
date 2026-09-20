#lang racket/base

(require racket/file
         racket/path
         racket/runtime-path
         racket/system
         "csharp-codegen.rkt"
         "project.rkt"
         "runtime.rkt"
         "windows-tools.rkt")

(provide build-dotnet-runtime!)

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
  (unless (and source (file-exists? source))
    (raise-arguments-error who
                           "required source file does not exist"
                           "source" source))
  (make-parent-directory* destination)
  (copy-file source destination #t))

(define (compile-backend! project runtime stage)
  (define backend (project-path project (project-ref project 'backend)))
  (unless (file-exists? backend)
    (raise-arguments-error 'build-dotnet-runtime!
                           "configured backend module does not exist"
                           "backend" backend))

  (define res-dir (build-path stage "res"))
  (define runtime-dir (build-path stage "runtime"))
  (make-directory* res-dir)
  (make-directory* runtime-dir)

  (define core (build-path res-dir "core.zo"))
  (run! 'build-dotnet-runtime!
        (find-executable-path "raco")
        "ctool"
        "--runtime" (path->string runtime-dir)
        "--runtime-access" "runtime"
        "--mods" (path->string core)
        (path->string backend))

  (for ([source (in-list
                 (list (racket-runtime-petite-boot runtime)
                       (racket-runtime-scheme-boot runtime)
                       (racket-runtime-racket-boot runtime)))])
    (copy-required! 'build-dotnet-runtime!
                    source
                    (build-path runtime-dir (file-name-from-path source))))
  core)

(define (prepare-import-library! project runtime lib-exe)
  (unless lib-exe
    (error 'build-dotnet-runtime!
           "MSVC lib.exe was not found; install the Desktop development with C++ workload"))
  (define build-dir (project-path project ".rivet" "build" "dotnet" "windows"))
  (make-directory* build-dir)
  (define output (build-path build-dir "libracketcs.lib"))
  (run! 'build-dotnet-runtime!
        lib-exe
        (string-append "/def:" (path->string (racket-runtime-racketcs-def runtime)))
        (string-append "/out:" (path->string output))
        "/machine:x64")
  output)

(define (with-build-environment runtime import-lib thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (define (set-path! key path)
    (environment-variables-set! env key (path->bytes path)))
  (set-path! #"RIVET_ROOT" (simplify-path rivet-root #t))
  (set-path! #"RIVET_RACKET_INCLUDE" (racket-runtime-include-dir runtime))
  (set-path! #"RIVET_RACKET_IMPORT_LIB" import-lib)
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (build-dotnet-runtime! project #:configuration [configuration "Release"])
  (unless (eq? (system-type 'os) 'windows)
    (error 'build-dotnet-runtime! ".NET embedded runtime packaging currently targets Windows"))
  (unless (eq? (system-type 'arch) 'x86_64)
    (error 'build-dotnet-runtime! "the first .NET embedded runtime milestone supports x64 only"))

  ;; The managed API and native bundle are generated from the same backend
  ;; schema in one command so a consumer cannot accidentally mix versions.
  (generate-csharp-client! project)

  (define runtime (discover-racket-runtime))
  (define stage (project-path project ".rivet" "dotnet" "windows-x64"))
  (fresh-directory! stage)
  (compile-backend! project runtime stage)

  (define racketcs-dll (racket-runtime-racketcs-dll runtime))
  (copy-required! 'build-dotnet-runtime!
                  racketcs-dll
                  (build-path stage (file-name-from-path racketcs-dll)))

  (define tools (discover-windows-toolchain))
  (define import-lib
    (prepare-import-library! project runtime (windows-toolchain-lib tools)))
  (define msbuild (windows-toolchain-msbuild tools))
  (unless msbuild
    (error 'build-dotnet-runtime! "MSBuild.exe was not found"))

  (define native-project
    (build-path (simplify-path rivet-root #t)
                "platform" "windows" "dotnet" "Rivet.Native.vcxproj"))
  (unless (file-exists? native-project)
    (error 'build-dotnet-runtime! "Rivet.Native.vcxproj is missing: ~a" native-project))

  (with-build-environment
   runtime import-lib
   (lambda ()
     (run! 'build-dotnet-runtime!
           msbuild
           (path->string native-project)
           "/m"
           (string-append "/p:Configuration=" configuration)
           "/p:Platform=x64"
           (string-append "/p:OutDir=" (path->string stage)))))

  (define dll (build-path stage "rivet_native.dll"))
  (unless (file-exists? dll)
    (error 'build-dotnet-runtime! "native bridge build completed but rivet_native.dll was not produced"))
  stage)
