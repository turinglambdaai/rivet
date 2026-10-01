#lang racket/base

(require json
         racket/file
         racket/list
         racket/port
         rackunit
         "../rivet-cli/inspect.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-inspect-~a" 'directory))

(dynamic-wind
 void
 (lambda ()
   (define root (create-project! "AgentDemo" temp-root))
   (define project (load-project root))
   (define report (project-report project))

   (check-equal? (hash-ref report 'contract-version) 1)
   (check-equal? (hash-ref report 'principles) '("Human-first" "Agent-native" "Local by design"))
   (check-equal? (hash-ref (hash-ref report 'project) 'name) "AgentDemo")
   (check-true (hash? (hash-ref (hash-ref report 'backend) 'source)))
   (check-true
    (hash-ref (hash-ref (hash-ref report 'schema) 'baseline) 'exists))

   (define sourcing (hash-ref report 'capability-sourcing))
   (check-equal? (hash-ref sourcing 'version) 1)
   (check-regexp-match #rx"narrowest maintainable boundary" (hash-ref sourcing 'policy))
   (check-equal? (hash-ref (hash-ref sourcing 'documentation) 'installed) "raco docs rivet")
   (check-equal? (map (lambda (option) (hash-ref option 'kind)) (hash-ref sourcing 'decision-order))
                 '("racket-library" "native-host" "ffi" "cli" "sidecar" "implement"))
   (check-not-false (member "license and redistribution" (hash-ref sourcing 'required-checks)))

   (define commands (hash-ref report 'commands))
   (check-not-false
    (findf (lambda (entry)
             (and (equal? (hash-ref entry 'name) "check-schema-compatibility")
                  (not (hash-ref entry 'mutates))))
           commands))

   (define edits (hash-ref report 'edit-points))
   (for* ([group (in-list '(shared-logic windows-ui macos-ui linux-ui configuration))]
          [entry (in-list (hash-ref edits group))])
     (check-true (hash-ref entry 'exists)))

   ;; Every supported client language is discoverable from the report,
   ;; including the Kotlin client inside the shared generated tree.
   (define clients (hash-ref report 'generated-clients))
   (for ([key (in-list '(swift cpp-windows cpp-linux kotlin))])
     (check-true (hash? (hash-ref clients key #f)))
     (check-true (string? (hash-ref (hash-ref clients key) 'path))))

   (check-equal?
    (map (lambda (entry) (hash-ref entry 'name)) (hash-ref report 'targets))
    '("windows" "macos" "linux" "ios" "ipados" "watchos" "android"))

   (check-true (file-exists? (build-path root "AGENTS.md")))
   (define instructions (file->string (build-path root "AGENTS.md")))
   (check-regexp-match #rx"raco rivet inspect --json" instructions)
   (check-regexp-match #rx"cross-platform UI DSL" instructions)
   (check-regexp-match #rx"Capability sourcing" instructions)
   (check-regexp-match #rx"never construct a shell command" instructions)
   (check-regexp-match #rx"raco rivet schema check rivet-schema.json --json" instructions)

   (define encoded
     (let ([out (open-output-string)])
       (parameterize ([current-output-port out])
         (check-equal? (run-inspect project #:json? #t) 0))
       (get-output-string out)))
   (define decoded (call-with-input-string encoded read-json))
   (check-equal? (hash-ref decoded 'contract-version) 1)
   (check-equal? (hash-ref (hash-ref decoded 'project) 'identifier) "dev.rivet.agentdemo")
   (check-equal? (hash-ref (car (hash-ref (hash-ref decoded 'capability-sourcing) 'decision-order))
                           'kind)
                 "racket-library")

   (define human
     (let ([out (open-output-string)])
       (parameterize ([current-output-port out])
         (check-equal? (run-inspect project) 0))
       (get-output-string out)))
   (check-regexp-match #rx"Rivet project: AgentDemo" human)
   (check-regexp-match #rx"raco rivet doctor --json" human)
   (check-regexp-match #rx"missing a capability:" human)
   (check-regexp-match #rx"racket-library" human))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
