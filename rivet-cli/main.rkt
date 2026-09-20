#lang racket/base

(require racket/match
         "build.rkt"
         "codegen.rkt"
         "csharp-codegen.rkt"
         "doctor.rkt"
         "dotnet-build.rkt"
         "package.rkt"
         "project.rkt"
         "scaffold.rkt")

(define (say fmt . args)
  (apply printf (string-append "rivet: " fmt "\n") args))

(define (die fmt . args)
  (apply eprintf (string-append "rivet: error: " fmt "\n") args)
  (exit 1))

(define (usage)
  (displayln
   (string-append
    "Rivet — build native desktop apps with Racket\n\n"
    "Usage:\n"
    "  raco rivet new <name>       create a new Rivet application\n"
    "  raco rivet doctor           inspect the local native toolchain\n"
    "  raco rivet generate         generate Swift, C++ and C# typed clients\n"
    "  raco rivet generate-dotnet  generate only the typed C# client\n"
    "  raco rivet build-dotnet     build the embedded Windows runtime for .NET\n"
    "  raco rivet build            compile backend and native host\n"
    "  raco rivet dev              build and run the current app\n"
    "  raco rivet package          create a distributable native package\n"
    "  raco rivet help             show this help\n")))

(define (current-project!)
  (or (find-project)
      (error 'rivet "no rivet.rktd found in this directory or its parents")))

(define (main)
  (define args (vector->list (current-command-line-arguments)))
  (match args
    [(or '() (list "help") (list "--help") (list "-h"))
     (usage)]
    [(list "new" name)
     (define root (create-project! name))
     (say "created ~a" root)
     (displayln "")
     (displayln (format "  cd ~a" name))
     (displayln "  raco rivet doctor")
     (displayln "  raco rivet dev")]
    [(list "doctor")
     (exit (run-doctor))]
    [(list "generate")
     (define project (current-project!))
     (generate-clients! project)
     (define csharp (generate-csharp-client! project))
     (say "generated Swift/C++ clients and ~a" csharp)]
    [(list "generate-dotnet")
     (define output (generate-csharp-client! (current-project!)))
     (say "generated ~a" output)]
    [(list "build-dotnet")
     (define output (build-dotnet-runtime! (current-project!)))
     (say "built .NET embedded runtime ~a" output)]
    [(list "build")
     (define output (build-project! (current-project!)))
     (say "built ~a" output)]
    [(list "dev")
     (dev-project! (current-project!))]
    [(list "package")
     (define output (package-project! (current-project!)))
     (say "packaged ~a" output)]
    [_
     (usage)
     (exit 1)]))

(with-handlers ([exn:fail?
                 (lambda (e)
                   (die "~a" (exn-message e)))])
  (main))
