#lang racket/base

;; Composes the family-wide update manifest from per-platform release legs.
;;
;; `raco rivet release` runs once per platform, so each leg emits its own
;; signed update manifest containing exactly one artifact. Multi-platform
;; products then hand-roll a merge (five repos, five schemes). This module
;; folds the per-platform manifests into one signed manifest — same
;; application identity, one artifact per (platform, architecture) — using
;; the same Ed25519 wrapper every client already verifies.

(require racket/file
         racket/list
         racket/match
         racket/set
         racket/path
         racket/string
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/manifest.rkt"
         "project.rkt"
         "signing-options.rkt")

(provide compose-manifests!
         parse-manifest-compose-arguments)

(define (parse-manifest-compose-arguments arguments)
  (let loop ([remaining arguments] [inputs '()] [output #f])
    (match remaining
      ['()
       (values (reverse inputs)
               (or output (build-path "dist" "update-family.json")))]
      [(list "--output")
       (raise-arguments-error
        'manifest-compose
        "--output requires a destination path")]
      [(list* "--output" destination tail)
       (when output
         (raise-arguments-error
          'manifest-compose
          "--output may be specified only once"))
       (when (regexp-match? #rx"^--" destination)
         (raise-arguments-error
          'manifest-compose
          "--output requires a destination path"
          "value" destination))
       (loop tail inputs (string->path destination))]
      [(cons argument tail)
       (when (regexp-match? #rx"^--" argument)
         (raise-arguments-error
          'manifest-compose
          "unknown option"
          "option" argument))
       (loop tail (cons (string->path argument) inputs) output)])))

(define (duplicates items)
  (define seen (mutable-set))
  (define repeated '())
  (for ([item (in-list items)])
    (if (set-member? seen item)
        (set! repeated (cons item repeated))
        (set-add! seen item)))
  (reverse repeated))

(define (compose-manifests! inputs output
                            #:private-key [private-key #f]
                            #:private-key-path [private-key-path #f]
                            #:key-id key-id)
  (when (null? inputs)
    (raise-argument-error 'compose-manifests! "at least one input manifest"))
  (define signing-key
    (cond
      [private-key private-key]
      [private-key-path (read-ed25519-private-key private-key-path)]
      [else
       (raise-arguments-error
        'compose-manifests!
        "a signing key is required (pass #:private-key or #:private-key-path)")]))
  (define manifests
    (for/list ([input (in-list inputs)])
      ;; Verify each independently signed release leg before the family key
      ;; endorses its payload again.
      (call-with-input-file
       input
       (lambda (in)
         (verify-signed-manifest in signing-key #:key-id key-id)))))
  (define (agree who accessor)
    (define values-seen
      (remove-duplicates (map accessor manifests) equal?))
    (unless (null? (cdr values-seen))
      (raise-arguments-error
       'compose-manifests!
       (string-append "input manifests disagree on " who)
       "values" values-seen))
    (car values-seen))
  (define application-id (agree "application id" update-manifest-application-id))
  (define version (agree "version" update-manifest-version))
  (define build (agree "build" update-manifest-build))
  (define channel (agree "channel" update-manifest-channel))
  (define minimum-version (agree "minimum version" update-manifest-minimum-version))
  (define previous-version
    (agree "previous version" update-manifest-previous-version))
  (define rollback-allowed?
    (agree "rollback policy" update-manifest-rollback-allowed?))
  (define rollout (agree "rollout" update-manifest-rollout))
  ;; published-at keeps the latest leg so the composed manifest is not
  ;; older than any input a client might still hold.
  (define published-at
    (last (sort (map update-manifest-published-at manifests) string<?)))
  (define artifacts
    (append* (map update-manifest-artifacts manifests)))
  (define repeated-pairs
    (duplicates (map (lambda (artifact)
                       (cons (update-artifact-platform artifact)
                             (update-artifact-architecture artifact)))
                     artifacts)))
  (unless (null? repeated-pairs)
    (raise-arguments-error
     'compose-manifests!
     "more than one artifact for the same platform and architecture"
     "duplicates" repeated-pairs))
  (define composed
    (update-manifest application-id version build channel published-at
                     minimum-version previous-version rollback-allowed?
                     rollout artifacts))
  (make-parent-directory* output)
  (call-with-output-file output
    #:exists 'truncate/replace
    (lambda (out)
      (write-signed-manifest composed signing-key key-id out)))
  output)



