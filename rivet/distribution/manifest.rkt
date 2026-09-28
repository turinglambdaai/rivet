#lang racket/base

(require json
         racket/list
         racket/match
         racket/port
         racket/string
         "crypto.rkt"
         "version.rkt")

(provide manifest-schema-version
         (struct-out update-artifact)
         (struct-out update-manifest)
         manifest->payload-bytes
         payload-bytes->manifest
         write-signed-manifest
         read-signed-manifest
         verify-signed-manifest)

(define manifest-schema-version 1)

(struct update-artifact
  (platform architecture url sha256 size installer arguments)
  #:transparent)

(struct update-manifest
  (application-id version build channel published-at minimum-version
                  previous-version rollback-allowed? rollout artifacts)
  #:transparent)

(define (required hash key predicate description)
  (define value
    (hash-ref hash key
              (lambda ()
                (raise-arguments-error 'payload-bytes->manifest
                                       "manifest field is missing"
                                       "field" key))))
  (unless (predicate value)
    (raise-arguments-error 'payload-bytes->manifest
                           "manifest field has invalid type or value"
                           "field" key
                           "expected" description
                           "value" value))
  value)

(define (artifact->jsexpr artifact)
  (hasheq 'platform (symbol->string (update-artifact-platform artifact))
          'architecture (symbol->string (update-artifact-architecture artifact))
          'url (update-artifact-url artifact)
          'sha256 (string-downcase (update-artifact-sha256 artifact))
          'size (update-artifact-size artifact)
          'installer (symbol->string (update-artifact-installer artifact))
          'arguments (update-artifact-arguments artifact)))

(define (manifest->payload-bytes manifest)
  (unless (update-manifest? manifest)
    (raise-argument-error 'manifest->payload-bytes "update-manifest?" manifest))
  (define out (open-output-bytes))
  (write-json
   (hasheq
    'schema manifest-schema-version
    'application_id (update-manifest-application-id manifest)
    'version (update-manifest-version manifest)
    'build (update-manifest-build manifest)
    'channel (symbol->string (update-manifest-channel manifest))
    'published_at (update-manifest-published-at manifest)
    'minimum_version (update-manifest-minimum-version manifest)
    'previous_version (or (update-manifest-previous-version manifest) 'null)
    'rollback_allowed (update-manifest-rollback-allowed? manifest)
    'rollout (update-manifest-rollout manifest)
    'artifacts (map artifact->jsexpr (update-manifest-artifacts manifest)))
   out)
  (get-output-bytes out))

(define (jsexpr->artifact value)
  (unless (hash? value)
    (raise-argument-error 'payload-bytes->manifest "artifact object" value))
  (define sha (required value 'sha256
                        (lambda (v) (and (string? v)
                                         (regexp-match? #px"^[0-9A-Fa-f]{64}$" v)))
                        "64 hexadecimal SHA-256 characters"))
  (update-artifact
   (string->symbol (required value 'platform string? "string"))
   (string->symbol (required value 'architecture string? "string"))
   (required value 'url
             (lambda (v) (and (string? v)
                              (regexp-match? #px"^https://" v)))
             "HTTPS URL")
   (string-downcase sha)
   (required value 'size exact-nonnegative-integer? "non-negative integer")
   (string->symbol (required value 'installer string? "string"))
   (required value 'arguments
             (lambda (v) (and (list? v) (andmap string? v)))
             "array of strings")))

(define (payload-bytes->manifest payload)
  (define value
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-arguments-error 'payload-bytes->manifest
                                              "payload is not valid JSON"
                                              "detail" (exn-message e)))])
      (read-json (open-input-bytes payload))))
  (unless (hash? value)
    (raise-argument-error 'payload-bytes->manifest "JSON object payload" value))
  (define schema (required value 'schema exact-integer? "integer"))
  (unless (= schema manifest-schema-version)
    (raise-arguments-error 'payload-bytes->manifest
                           "unsupported update manifest schema"
                           "configured" schema
                           "supported" manifest-schema-version))
  (define version (required value 'version version? "SemVer 2.0 string"))
  (define channel-text (required value 'channel string? "string"))
  (define channel (string->symbol channel-text))
  (unless (valid-channel? channel)
    (raise-arguments-error 'payload-bytes->manifest
                           "unsupported release channel"
                           "channel" channel-text))
  (unless (channel-accepts-version? channel version)
    (raise-arguments-error 'payload-bytes->manifest
                           "version is incompatible with its release channel"
                           "version" version
                           "channel" channel))
  (define rollout
    (required value 'rollout
              (lambda (v) (and (exact-integer? v) (<= 0 v 100)))
              "integer from 0 through 100"))
  (define previous (hash-ref value 'previous_version 'null))
  (unless (or (eq? previous 'null) (version? previous))
    (raise-arguments-error 'payload-bytes->manifest
                           "previous_version must be null or SemVer"
                           "value" previous))
  (update-manifest
   (required value 'application_id
             (lambda (v) (and (string? v) (not (string=? v ""))))
             "non-empty string")
   version
   (required value 'build exact-positive-integer? "positive integer")
   channel
   (required value 'published_at
             (lambda (v)
               (and (string? v)
                    (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" v)))
             "UTC RFC 3339 timestamp")
   (required value 'minimum_version version? "SemVer 2.0 string")
   (and (not (eq? previous 'null)) previous)
   (required value 'rollback_allowed boolean? "boolean")
   rollout
   (map jsexpr->artifact
        (required value 'artifacts list? "array"))))

(define (signed-wrapper payload key-id signature)
  (hasheq 'schema manifest-schema-version
          'payload (bytes->base64-string payload)
          'signature
          (hasheq 'algorithm "ed25519"
                  'key_id key-id
                  'value (bytes->base64-string signature))))

(define (write-signed-manifest manifest private-key key-id [out (current-output-port)])
  (unless (and (string? key-id) (not (string=? key-id "")))
    (raise-argument-error 'write-signed-manifest "non-empty string?" key-id))
  (define payload (manifest->payload-bytes manifest))
  ;; Validate programmatically constructed structs before signing them. A
  ;; publisher must never be able to produce a signed manifest that every
  ;; client will reject.
  (void (payload-bytes->manifest payload))
  (write-json (signed-wrapper payload key-id (ed25519-sign private-key payload)) out)
  (newline out))

(define (read-wrapper input)
  (define value (read-json input))
  (unless (hash? value)
    (raise-argument-error 'read-signed-manifest "JSON object" value))
  (define schema (required value 'schema exact-integer? "integer"))
  (unless (= schema manifest-schema-version)
    (raise-arguments-error 'read-signed-manifest
                           "unsupported signed wrapper schema"
                           "configured" schema
                           "supported" manifest-schema-version))
  (define signature (required value 'signature hash? "object"))
  (define algorithm (required signature 'algorithm string? "string"))
  (unless (string=? algorithm "ed25519")
    (raise-arguments-error 'read-signed-manifest
                           "unsupported manifest signature algorithm"
                           "algorithm" algorithm))
  (values
   (base64-string->bytes (required value 'payload string? "base64 string"))
   (required signature 'key_id string? "string")
   (base64-string->bytes (required signature 'value string? "base64 string"))))

(define (read-signed-manifest input)
  (define-values (payload key-id signature) (read-wrapper input))
  (values (payload-bytes->manifest payload) payload key-id signature))

(define (verify-signed-manifest input public-key #:key-id [expected-key-id #f])
  (define-values (manifest payload key-id signature) (read-signed-manifest input))
  (when (and expected-key-id (not (string=? expected-key-id key-id)))
    (raise-arguments-error 'verify-signed-manifest
                           "manifest was signed by an unexpected key"
                           "expected" expected-key-id
                           "actual" key-id))
  (unless (ed25519-verify public-key payload signature)
    (error 'verify-signed-manifest "Ed25519 manifest signature verification failed"))
  manifest)
