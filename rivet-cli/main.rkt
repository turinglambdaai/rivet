#lang racket/base

;; Subcommand modules are loaded lazily via dynamic-require. Loading them at
;; the top level means any stale bytecode cache in a linked checkout
;; (instantiate-linklet mismatch after `git pull` moves modules) crashes raco
;; command dispatch itself with a raw linklet dump, before any Rivet code —
;; including doctor — can run or explain the fix. With lazy loading the
;; failure happens inside the handler at the bottom of this file, which
;; prints the working remedy. See issue #145.

(require json
         racket/match)

(define (say fmt . args)
  (apply printf (string-append "rivet: " fmt "\n") args))

(define (die fmt . args)
  (apply eprintf (string-append "rivet: error: " fmt "\n") args)
  (exit 1))

(define (command module symbol)
  (dynamic-require (string->symbol (string-append "rivet-cli/" module)) symbol))

(define (current-project!)
  (define find-project (command "project" 'find-project))
  (or (find-project)
      (error 'rivet "no rivet.rktd found in this directory or its parents")))

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

(define (main)
  (define args (vector->list (current-command-line-arguments)))
  (match args
    [(or '() (list "help") (list "--help") (list "-h"))
     (usage)]
    [(list "new" name)
     (define create-project! (command "scaffold" 'create-project!))
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
     (define run-doctor (command "doctor" 'run-doctor))
     (exit (run-doctor))]
    [(list "doctor" "--json")
     (define run-doctor (command "doctor" 'run-doctor))
     (exit (run-doctor #:json? #t))]
    [(list "inspect")
     (define run-inspect (command "inspect" 'run-inspect))
     (exit (run-inspect (current-project!)))]
    [(list "inspect" "--json")
     (define run-inspect (command "inspect" 'run-inspect))
     (exit (run-inspect (current-project!) #:json? #t))]
    [(list "schema" "--json")
     (define schema-snapshot (command "codegen" 'schema-snapshot))
     (write-json (schema-snapshot (current-project!)))
     (newline)]
    [(list "schema" "--output" output)
     (define write-schema-snapshot! (command "codegen" 'write-schema-snapshot!))
     (define destination
       (write-schema-snapshot! (current-project!) output))
     (say "wrote schema baseline ~a" destination)]
    [(or (list "schema" "check" baseline)
         (list "schema" "check" baseline "--json"))
     (define check-schema-compatibility! (command "codegen" 'check-schema-compatibility!))
     (define report
       (check-schema-compatibility! (current-project!) baseline))
     (define json? (equal? args (list "schema" "check" baseline "--json")))
     (if json?
         (begin (write-json report)
                (newline))
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
     (define clean-project! (command "clean" 'clean-project!))
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
     (define generate-clients! (command "codegen" 'generate-clients!))
     (generate-clients! (current-project!))
     (say "generated Swift, C++, and Kotlin clients")]
    [(list "build")
     (define build-project! (command "build" 'build-project!))
     (define output (build-project! (current-project!)))
     (say "built ~a" output)]
    [(list "dev")
     (define dev-project! (command "build" 'dev-project!))
     (dev-project! (current-project!))]
    [(list "package")
     (define package-project! (command "package" 'package-project!))
     (define output (package-project! (current-project!)))
     (say "packaged and verified ~a" output)]
    [(list "package" "--skip-launch-smoke")
     (define package-project! (command "package" 'package-project!))
     (define output
       (package-project! (current-project!) #:launch-smoke? #f))
     (say "packaged and verified ~a (launch smoke skipped)" output)]
    [(or (list "package" "--production")
         (list "package" "--production" "--skip-launch-smoke")
         (list "package" "--skip-launch-smoke" "--production"))
     (define package-project! (command "package" 'package-project!))
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
     (define release-project! (command "release" 'release-project!))
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
     (define verify-project-package! (command "verify" 'verify-project-package!))
     (define output (verify-project-package! (current-project!)))
     (say "verified ~a" output)]
    [(list "verify" "--skip-launch-smoke")
     (define verify-project-package! (command "verify" 'verify-project-package!))
     (define output
       (verify-project-package! (current-project!) #:launch-smoke? #f))
     (say "verified ~a (launch smoke skipped)" output)]
    [(or (list "verify" "--production")
         (list "verify" "--production" "--skip-launch-smoke")
         (list "verify" "--skip-launch-smoke" "--production"))
     (define verify-project-package! (command "verify" 'verify-project-package!))
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
     (define generate-compliance-artifacts!
       (command "compliance" 'generate-compliance-artifacts!))
     (define-values (sbom notices)
       (generate-compliance-artifacts! (current-project!)))
     (say "license audit passed; SBOM: ~a" sbom)
     (say "third-party notices: ~a" notices)]
    [_
     (usage)
     (exit 1)]))

(define (stale-cache-remedy)
  (eprintf "rivet: this error is typical of a stale bytecode cache in a linked\n")
  (eprintf "rivet: rivet checkout after `git pull` moved modules. Fix, from the\n")
  (eprintf "rivet: rivet checkout root:\n")
  (eprintf "  find . -name compiled -type d -prune -exec rm -rf {} +\n")
  (eprintf "  raco setup rivet\n")
  (eprintf "rivet: then rerun the command. See CONTRIBUTING.md.\n"))

(with-handlers ([exn:fail?
                 (lambda (e)
                   (when (regexp-match? #rx"instantiate-linklet: mismatch"
                                        (exn-message e))
                     (stale-cache-remedy))
                   (die "~a" (exn-message e)))])
  (main))
