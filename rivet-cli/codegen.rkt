#lang racket/base

(require racket/file
         "project.rkt"
         "codegen/cpp.rkt"
         "codegen/kotlin.rkt"
         "codegen/model.rkt"
         "codegen/naming.rkt"
         "codegen/snapshot.rkt"
         "codegen/swift.rkt"
         "codegen/type-graph.rkt")

(provide generate-clients!
         check-generated-clients
         schema-snapshot
         write-schema-snapshot!
         check-schema-compatibility!)

(define (write-generated! path content)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display content out))))

;; Computes the full set of generated client files as (path . content) pairs
;; without touching the disk, plus the schema summary generate-clients!
;; returns. generate-clients! writes these pairs; check-generated-clients
;; diffs them against the tree, so the freshness gate and the writer can
;; never disagree about what a fresh tree looks like.
(define (client-outputs project)
  (define backend (project-path project (project-ref project 'backend)))
  (define-values (rpcs events states records enums)
    (load-schema backend #:id (project-identifier project)))
  (define module-name (project-ref project 'module))
  (define entry-name (project-ref project 'entry))
  (define display-name (project-display-name project))
  (define version (project-version project))
  (define build (project-build project))
  (define identifier (project-identifier project))
  (define release-channel (symbol->string (project-release-channel project)))
  (define device-rpcs (resolve-device-rpcs project rpcs))
  (unless (and (string? module-name) (string? entry-name))
    (error 'generate-clients! "project module and entry settings must be strings"))
  (when (and (null? rpcs) (null? events) (null? states) (null? records) (null? enums))
    (error 'generate-clients! "the backend declares no RPCs, Events, shared states, Records, or Enums"))
  (validate-native-identifiers! rpcs events states records enums device-rpcs)
  (define outputs
    (parameterize ([current-records records]
                   [current-enums enums])
      ;; Force dependency ordering first so recursive record graphs fail before
      ;; companion-channel Codable analysis attempts to walk them.
      (define schema-types (all-types rpcs events states records enums))
      (define codable-types (device-codable-named-types device-rpcs))
      (void schema-types)
      (validate-device-rpcs! device-rpcs)
      (define pairs
        (list
         (cons (project-path project "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")
               (parameterize ([current-swift-codable-types codable-types])
                 (generate-swift rpcs events states records enums device-rpcs
                                 module-name entry-name display-name version build
                                 identifier release-channel)))
         (cons (project-path project "windows" "GeneratedBackend.hpp")
               (generate-cpp rpcs events states records enums
                             module-name entry-name display-name version build
                             identifier release-channel "rivet::windows"))
         ;; Android consumes the typed client from the shared generated tree
         ;; until generated Compose projects exist; the package layout keeps
         ;; the file drop-in for Gradle source sets.
         (cons (project-path project ".rivet" "generated" "kotlin" "dev" "rivet"
                             "generated" "GeneratedBackend.kt")
               (generate-kotlin rpcs events states records enums
                                module-name entry-name display-name version build
                                identifier release-channel))))
      (define linux-host (project-path project "linux"))
      (if (directory-exists? linux-host)
          (cons (cons (build-path linux-host "GeneratedBackend.hpp")
                      (generate-cpp rpcs events states records enums
                                    module-name entry-name display-name version build
                                    identifier release-channel "rivet::linux_runtime"))
                pairs)
          pairs)))
  (cons outputs (list rpcs states events records enums)))

(define (generate-clients! project)
  (define plan (client-outputs project))
  (for ([pair (in-list (car plan))])
    (write-generated! (car pair) (cdr pair)))
  ;; Preserve the historical first two result positions for callers that
  ;; inspect codegen output programmatically; Events, Records, and Enums follow.
  (cdr plan))

;; The release freshness gate (issue #245): regenerate in memory and compare
;; with the tree. Because the regenerated content always carries the current
;; rivet.rktd version/build stamp, a hand-edited version literal or a
;; forgotten regeneration after a version bump shows up as a stale file.
(define (check-generated-clients project)
  (define outputs (car (client-outputs project)))
  (define fresh '())
  (define stale '())
  (define missing '())
  (for ([pair (in-list outputs)])
    (define path (car pair))
    (cond
      [(not (file-exists? path)) (set! missing (cons path missing))]
      [(not (string=? (file->string path) (cdr pair)))
       (set! stale (cons path stale))]
      [else (set! fresh (cons path fresh))]))
  (hash 'fresh (reverse fresh)
        'stale (reverse stale)
        'missing (reverse missing)))
