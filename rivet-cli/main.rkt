#lang racket/base

(require json
         racket/match
         "build.rkt"
         "clean.rkt"
         "codegen.rkt"
         "compliance.rkt"
         "doctor.rkt"
         "inspect.rkt"
         "package.rkt"
         "project.rkt"
         "release.rkt"
         "scaffold.rkt"
         "verify.rkt")

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
    "  raco rivet new <name>              create a new Rivet application\n"
    "  raco rivet doctor                  inspect the local native toolchain\n"
    "  raco rivet doctor --json           emit machine-readable toolchain diagnostics\n"
    "  raco rivet inspect                 show the current project's edit and verification map\n"
    "  raco rivet inspect --json          emit the agent-readable project contract\n"
    "  raco rivet schema --json           emit the current versioned API schema\n"
    "  raco rivet schema --output <file>  write a schema compatibility baseline\n"
    "  raco rivet schema check <file>     reject breaking changes from a baseline\n"
    "  raco rivet schema check <file> --json  emit a machine-readable compatibility report\n"
    "  raco rivet clean                   remove generated .rivet/build/dist artifacts\n"
    "  raco rivet build                   compile backend and native host\n"
    "  raco rivet dev                     build and run the current app\n"
    "  raco rivet package                 create and verify a development distributable\n"
    "  raco rivet package --production    create, sign, and verify a production distributable\n"
    "  raco rivet package --skip-launch-smoke  package without starting the GUI artifact\n"
    "  raco rivet release                 build signed installer, update manifest, SBOM, and notices\n"
    "  raco rivet release --development   exercise release flow without platform production signing\n"
    "  raco rivet release --without-updates  release without an update manifest or update key\n"
    "  raco rivet compliance              generate SBOM/notices and run the license audit\n"
    "  raco rivet verify                  re-verify the current packaged artifact\n"
    "  raco rivet verify --production     verify production trust/notarization requirements\n"
    "  raco rivet verify --skip-launch-smoke  verify without starting the GUI artifact\n"
    "  raco rivet help                    show this help\n")))

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
     (displayln "Next:")
     (displayln (format "  cd ~a" name))
     (displayln "  raco rivet doctor")
     (displayln "  raco rivet dev")
     (displayln "")
     (displayln "The generated README.md points to the backend and native UI files to edit.")
     (displayln "Guide: https://github.com/turinglambdaai/rivet/blob/main/docs/getting-started.md")
     (displayln "中文教程: https://github.com/turinglambdaai/rivet/blob/main/docs/getting-started.zh-CN.md")]
    [(list "doctor")
     (exit (run-doctor))]
    [(list "doctor" "--json")
     (exit (run-doctor #:json? #t))]
    [(list "inspect")
     (exit (run-inspect (current-project!)))]
    [(list "inspect" "--json")
     (exit (run-inspect (current-project!) #:json? #t))]
    [(list "schema" "--json")
     (write-json (schema-snapshot (current-project!)))
     (newline)]
    [(list "schema" "--output" output)
     (define destination
       (write-schema-snapshot! (current-project!) output))
     (say "wrote schema baseline ~a" destination)]
    [(or (list "schema" "check" baseline)
         (list "schema" "check" baseline "--json"))
     (define report
       (check-schema-compatibility! (current-project!) baseline))
     (define json? (equal? args (list "schema" "check" baseline "--json")))
     (if json?
         (begin (write-json report) (newline))
         (begin
           (if (hash-ref report 'compatible)
               (say "schema is backward compatible with ~a" baseline)
               (begin
                 (say "schema has ~a breaking change~a compared with ~a"
                      (length (hash-ref report 'breaking-changes))
                      (if (= (length (hash-ref report 'breaking-changes)) 1) "" "s")
                      baseline)
                 (for ([item (in-list (hash-ref report 'breaking-changes))])
                   (printf "  - ~a\n" (hash-ref item 'message)))))
           (unless (null? (hash-ref report 'compatible-additions))
             (say "compatible additions: ~a"
                  (length (hash-ref report 'compatible-additions))))))
     (unless (hash-ref report 'compatible) (exit 1))]
    [(list "clean")
     (define removed (clean-project! (current-project!)))
     (if (null? removed)
         (say "project is already clean")
         (begin
           (say "removed ~a generated path~a"
                (length removed)
                (if (= (length removed) 1) "" "s"))
           (for ([path (in-list removed)])
             (printf "  ~a\n" path))))]
    [(list "generate")
     (generate-clients! (current-project!))
     (say "generated Swift, C++, and Kotlin clients")]
    [(list "build")
     (define output (build-project! (current-project!)))
     (say "built ~a" output)]
    [(list "dev")
     (dev-project! (current-project!))]
    [(list "package")
     (define output (package-project! (current-project!)))
     (say "packaged and verified ~a" output)]
    [(list "package" "--skip-launch-smoke")
     (define output
       (package-project! (current-project!) #:launch-smoke? #f))
     (say "packaged and verified ~a (launch smoke skipped)" output)]
    [(or (list "package" "--production")
         (list "package" "--production" "--skip-launch-smoke")
         (list "package" "--skip-launch-smoke" "--production"))
     (define launch-smoke?
       (not (member "--skip-launch-smoke" args)))
     (define output
       (package-project! (current-project!)
                         #:production? #t
                         #:launch-smoke? launch-smoke?))
     (say "production packaged, signed, and verified ~a~a"
          output
          (if launch-smoke? "" " (launch smoke skipped)"))]
    [(or (list "release")
         (list "release" "--development")
         (list "release" "--without-updates")
         (list "release" "--development" "--without-updates")
         (list "release" "--without-updates" "--development"))
     (define production? (not (member "--development" args)))
     (define updates? (not (member "--without-updates" args)))
     (define-values (installer manifest sbom notices)
       (release-project! (current-project!)
                         #:production? production?
                         #:updates? updates?))
     (say "release installer: ~a" installer)
     (if manifest
         (say "signed update manifest: ~a" manifest)
         (say "update manifest: skipped (--without-updates)"))
     (say "SBOM: ~a" sbom)
     (say "third-party notices: ~a" notices)]
    [(list "verify")
     (define output (verify-project-package! (current-project!)))
     (say "verified ~a" output)]
    [(list "verify" "--skip-launch-smoke")
     (define output
       (verify-project-package! (current-project!) #:launch-smoke? #f))
     (say "verified ~a (launch smoke skipped)" output)]
    [(or (list "verify" "--production")
         (list "verify" "--production" "--skip-launch-smoke")
         (list "verify" "--skip-launch-smoke" "--production"))
     (define launch-smoke?
       (not (member "--skip-launch-smoke" args)))
     (define output
       (verify-project-package! (current-project!)
                                #:production? #t
                                #:launch-smoke? launch-smoke?))
     (say "production trust verified ~a~a"
          output
          (if launch-smoke? "" " (launch smoke skipped)"))]
    [(list "compliance")
     (define-values (sbom notices)
       (generate-compliance-artifacts! (current-project!)))
     (say "license audit passed; SBOM: ~a" sbom)
     (say "third-party notices: ~a" notices)]
    [_
     (usage)
     (exit 1)]))

(with-handlers ([exn:fail?
                 (lambda (e)
                   (die "~a" (exn-message e)))])
  (main))
