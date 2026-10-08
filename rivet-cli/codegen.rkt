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
         schema-snapshot
         write-schema-snapshot!
         check-schema-compatibility!)

(define (write-generated! path content)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display content out))))

(define (generate-clients! project)
  (define backend (project-path project (project-ref project 'backend)))
  (define-values (rpcs events states records enums) (load-schema backend))
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
  (parameterize ([current-records records]
                 [current-enums enums])
    ;; Force dependency ordering first so recursive record graphs fail before
    ;; companion-channel Codable analysis attempts to walk them.
    (define schema-types (all-types rpcs events states records enums))
    (define codable-types (device-codable-named-types device-rpcs))
    (void schema-types)
    (validate-device-rpcs! device-rpcs)
    (parameterize ([current-swift-codable-types codable-types])
      (write-generated!
       (project-path project "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")
       (generate-swift rpcs events states records enums device-rpcs
                       module-name entry-name display-name version build
                       identifier release-channel)))
    (write-generated!
     (project-path project "windows" "GeneratedBackend.hpp")
     (generate-cpp rpcs events states records enums
                   module-name entry-name display-name version build
                   identifier release-channel "rivet::windows"))
    (define linux-host (project-path project "linux"))
    (when (directory-exists? linux-host)
      (write-generated!
       (build-path linux-host "GeneratedBackend.hpp")
       (generate-cpp rpcs events states records enums
                     module-name entry-name display-name version build
                     identifier release-channel "rivet::linux_runtime")))
    ;; Android consumes the typed client from the shared generated tree until
    ;; generated Compose projects exist; the package layout keeps the file
    ;; drop-in for Gradle source sets.
    (write-generated!
     (project-path project ".rivet" "generated" "kotlin" "dev" "rivet"
                   "generated" "GeneratedBackend.kt")
     (generate-kotlin rpcs events states records enums
                      module-name entry-name display-name version build
                      identifier release-channel)))
  ;; Preserve the historical first two result positions for callers that
  ;; inspect codegen output programmatically; Events, Records, and Enums follow.
  (list rpcs states events records enums))
