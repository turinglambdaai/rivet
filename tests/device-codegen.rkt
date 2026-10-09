#lang racket/base

(require rackunit
         racket/file
         racket/string
         "../rivet-cli/codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-device-codegen-~a" 'directory))

(define (write-value! path value)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (write value out))))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "device-codegen" temp-root))
    (define config-path (build-path project-root "rivet.rktd"))
    (define base-config (call-with-input-file config-path read))
    (define (set-device-rpcs! names)
      (write-value! config-path (hash-set base-config 'device-rpcs names)))

    (call-with-output-file
     (build-path project-root "app" "backend.rkt")
     #:exists 'truncate/replace
     (lambda (out)
       (display
        #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-enum AccessLevel (viewer editor owner))

(define-record Profile
  ([id : Int64]
   [name : String]
   [access : AccessLevel]
   [aliases : (List String)]))

(define-rpc (fetch-profile [id : Int64] : (Optional Profile))
  (void))

(define-rpc (refresh : Void)
  (void))

(define-rpc (raw-value [value : Any] : Any)
  value)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
        out)))

    ;; Companion APIs are default-deny and only the configured RPCs appear in
    ;; the generated Codable request/client/router surface.
    (set-device-rpcs! '(fetch-profile refresh))
    (define project (load-project project-root))
    (generate-clients! project)
    (define swift
      (file->string
       (build-path project-root "macos-host" "Sources" "RivetHost"
                   "GeneratedBackend.swift")))
    (for ([fragment (in-list
                     '("import RivetDevice"
                       "public enum RivetTypes"
                       "public enum AccessLevel: String, Codable, Sendable"
                       "public struct Profile: Codable, Sendable"
                       "public struct FetchProfile: RivetDeviceRequest"
                       "public typealias Response = RivetTypes.Profile?"
                       "public static let route = \"rpc.fetch-profile\""
                       "func fetch_profile(id: Int64) async throws -> RivetTypes.Profile?"
                       "func refresh() async throws"
                       "func registerGeneratedBackend(_ api: RivetAPI) throws"
                       "return RivetDeviceUnit()"))])
      (check-true (string-contains? swift fragment) fragment))
    (check-false (string-contains? swift "public struct RawValue:"))

    ;; Export removals are breaking because an installed companion may still
    ;; call the route; additions are compatible with existing companions.
    (define exported-baseline (build-path project-root ".rivet" "device-exported.json"))
    (write-schema-snapshot! project exported-baseline)
    (set-device-rpcs! '())
    (define removal-report
      (check-schema-compatibility! (load-project project-root) exported-baseline))
    (check-false (hash-ref removal-report 'compatible))
    (check-equal?
     (map (lambda (change) (hash-ref change 'name))
          (hash-ref removal-report 'breaking-changes))
     '("fetch-profile" "refresh"))

    (define empty-baseline (build-path project-root ".rivet" "device-empty.json"))
    (write-schema-snapshot! (load-project project-root) empty-baseline)
    (set-device-rpcs! '(fetch-profile refresh))
    (define addition-report
      (check-schema-compatibility! (load-project project-root) empty-baseline))
    (check-true (hash-ref addition-report 'compatible))

    ;; Dynamic Any values cannot cross the Codable companion boundary, and a
    ;; typo in the allowlist is rejected instead of silently exposing nothing.
    (set-device-rpcs! '(raw-value))
    (check-exn #rx"not representable by the Codable companion channel"
               (lambda () (generate-clients! (load-project project-root))))
    (check-exn #rx"not representable by the Codable companion channel"
               (lambda () (schema-snapshot (load-project project-root))))
    (set-device-rpcs! '(missing-rpc))
    (check-exn #rx"does not declare"
               (lambda () (generate-clients! (load-project project-root)))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
