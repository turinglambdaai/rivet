#lang racket/base

(require json
         racket/file
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
    (check-equal? (hash-ref report 'principles)
                  '("Human-first" "Agent-native" "Local by design"))
    (check-equal? (hash-ref (hash-ref report 'project) 'name) "AgentDemo")
    (check-true (hash? (hash-ref (hash-ref report 'backend) 'source)))

    (define edits (hash-ref report 'edit-points))
    (for* ([group (in-list '(shared-logic windows-ui macos-ui linux-ui configuration))]
           [entry (in-list (hash-ref edits group))])
      (check-true (hash-ref entry 'exists)))

    (check-true (file-exists? (build-path root "AGENTS.md")))
    (define instructions (file->string (build-path root "AGENTS.md")))
    (check-regexp-match #rx"raco rivet inspect --json" instructions)
    (check-regexp-match #rx"cross-platform UI DSL" instructions)

    (define encoded
      (let ([out (open-output-string)])
        (parameterize ([current-output-port out])
          (check-equal? (run-inspect project #:json? #t) 0))
        (get-output-string out)))
    (define decoded (call-with-input-string encoded read-json))
    (check-equal? (hash-ref decoded 'contract-version) 1)
    (check-equal? (hash-ref (hash-ref decoded 'project) 'identifier)
                  "dev.rivet.agentdemo")

    (define human
      (let ([out (open-output-string)])
        (parameterize ([current-output-port out])
          (check-equal? (run-inspect project) 0))
        (get-output-string out)))
    (check-regexp-match #rx"Rivet project: AgentDemo" human)
    (check-regexp-match #rx"raco rivet doctor --json" human))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
