#lang racket/base

(require json
         racket/file
         racket/list
         racket/port
         rackunit
         "../../rivet-cli/inspect.rkt"
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/scaffold.rkt")

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
   (check-equal? (hash-ref (hash-ref report 'project) 'publisher) "AgentDemo")
   (check-true (hash? (hash-ref (hash-ref report 'backend) 'source)))
   (check-true
    (hash-ref (hash-ref (hash-ref report 'schema) 'baseline) 'exists))
   (check-true
    (hash-ref (hash-ref report 'readiness) 'schema-baseline-configured))
   (check-true
    (hash-ref (hash-ref report 'readiness) 'acceptance-manifest-configured))
   (check-equal? (hash-ref (hash-ref report 'readiness) 'warnings) '())

   (define transport (hash-ref report 'transport-contract))
   (check-equal? (hash-ref transport 'rvt1-version) 1)
   (check-equal? (hash-ref transport 'deferred-keel-types)
                 '("Float64" "Map" "Error"))
   (check-regexp-match #rx"explicit protocol negotiation"
                       (hash-ref transport 'extension-policy))
   (define device-surface (hash-ref report 'device-surface))
   (check-true (hash-ref device-surface 'default-deny))
   (check-equal? (hash-ref device-surface 'configured-rpcs) '())
   (check-equal? (hash-ref device-surface 'network-gateway-status) "framework-core")
   (check-not-false
    (member "pairing-state-machine" (hash-ref device-surface 'implemented)))
   (check-not-false
    (member "secure-storage-adapter" (hash-ref device-surface 'implemented)))
   (check-false
    (member "secure-storage-adapter" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "session-preface" (hash-ref device-surface 'implemented)))
   (check-false
    (member "session-preface" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "network-listener" (hash-ref device-surface 'implemented)))
   (check-not-false
    (member "server-identity" (hash-ref device-surface 'implemented)))
   (check-false
    (member "network-listener" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "tls-adapter" (hash-ref device-surface 'implemented)))
   (check-false
    (member "tls-adapter" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "discovery" (hash-ref device-surface 'implemented)))
   (check-false
    (member "discovery" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "session-host" (hash-ref device-surface 'implemented)))
   (check-false
    (member "session-host" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "session-client" (hash-ref device-surface 'implemented)))
   (check-false
    (member "session-client" (hash-ref device-surface 'pending)))
   (check-not-false
    (member "product-ui" (hash-ref device-surface 'pending)))

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
             (and (equal? (hash-ref entry 'name) "acceptance")
                  (not (hash-ref entry 'mutates))))
           commands))
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
   (check-equal?
    (hash-ref (third (hash-ref report 'targets)) 'status)
    "production-target")

   ;; Mature applications rename and split the scaffold's native entry files.
   ;; Inspect the sources that actually exist instead of reporting the old
   ;; scaffold names as missing.
   (delete-file (build-path root "macos-host" "Sources" "RivetHost" "ContentView.swift"))
   (delete-file (build-path root "macos-host" "Sources" "RivetHost" "RivetHostApp.swift"))
   (call-with-output-file (build-path root "macos-host" "Sources" "RivetHost" "AgentDemoApp.swift")
     #:exists 'truncate
     (lambda (out) (display "// custom app entry\n" out)))
   (define custom-report (project-report project))
   (define custom-macos (hash-ref (hash-ref custom-report 'edit-points) 'macos-ui))
   ;; Reported paths are path->string output, so separators follow the host
   ;; — build the expectation instead of hardcoding forward slashes.
   (check-equal? (map (lambda (entry) (hash-ref entry 'path)) custom-macos)
                 (list (path->string
                        (build-path "macos-host" "Sources" "RivetHost"
                                    "AgentDemoApp.swift"))))
   (check-true (andmap (lambda (entry) (hash-ref entry 'exists)) custom-macos))

   (delete-file (build-path root "rivet-schema.json"))
   (define missing-baseline-report (project-report project))
   (check-false
    (hash-ref (hash-ref missing-baseline-report 'readiness) 'schema-baseline-configured))
   (check-equal?
    (hash-ref (car (hash-ref (hash-ref missing-baseline-report 'readiness) 'warnings)) 'code)
    "missing-schema-baseline")

   (check-true (file-exists? (build-path root "AGENTS.md")))
   (check-true (file-exists? (build-path root "rivet-acceptance.rktd")))
   (define instructions (file->string (build-path root "AGENTS.md")))
   (check-regexp-match #rx"raco rivet inspect --json" instructions)
   (check-regexp-match #rx"cross-platform UI DSL" instructions)
   (check-regexp-match #rx"Capability sourcing" instructions)
   (check-regexp-match #rx"never construct a shell command" instructions)
   (check-regexp-match #rx"raco rivet schema check rivet-schema.json --json" instructions)
   (check-regexp-match #rx"raco rivet acceptance --json" instructions)

   (delete-file (build-path root "rivet-acceptance.rktd"))
   (define missing-acceptance-report (project-report project))
   (check-false
    (hash-ref (hash-ref missing-acceptance-report 'readiness)
              'acceptance-manifest-configured))
   (check-not-false
    (for/or ([warning (in-list
                       (hash-ref (hash-ref missing-acceptance-report 'readiness)
                                 'warnings))])
      (string=? (hash-ref warning 'code) "missing-acceptance-manifest")))

   (define encoded
     (let ([out (open-output-string)])
       (parameterize ([current-output-port out])
         (check-equal? (run-inspect project #:json? #t) 0))
       (get-output-string out)))
   (define decoded (call-with-input-string encoded read-json))
   (check-equal? (hash-ref decoded 'contract-version) 1)
   (check-equal? (hash-ref (hash-ref decoded 'project) 'identifier) "dev.rivet.agentdemo")
   (check-equal? (hash-ref (hash-ref decoded 'project) 'publisher) "AgentDemo")
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
