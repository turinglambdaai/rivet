#lang racket/base

(provide (struct-out privileged-service-state)
         (struct-out privileged-service-adapter)
         current-privileged-service-adapter
         privileged-service-capabilities
         privileged-service-status
         privileged-service-start!
         privileged-service-stop!
         privileged-service-reload!)

;; Rivet applications sometimes need a small first-party privileged companion:
;; a NetworkExtension packet tunnel, Android VpnService, Windows service, or a
;; system daemon. This module owns only the lifecycle boundary. The service's
;; protocol, configuration schema, permissions, and product behavior stay in
;; the application adapter rather than becoming part of RVT1. Adapter fields
;; are Racket procedures; native hosts never install them by passing Racket or
;; Chez values across the embedding boundary.
(struct privileged-service-state (state detail revision)
  #:transparent)

(struct privileged-service-adapter
  (name capabilities status start stop reload)
  #:transparent)

(define max-service-id-length 256)
(define max-configuration-size (* 16 1024 1024))
(define max-state-detail-length 4096)

(define (unsupported operation)
  (lambda args
    (error operation
           "no native Rivet privileged-service adapter is installed")))

(define unavailable-adapter
  (privileged-service-adapter
   'unavailable
   '()
   (unsupported 'privileged-service-status)
   (unsupported 'privileged-service-start!)
   (unsupported 'privileged-service-stop!)
   (unsupported 'privileged-service-reload!)))

(define current-privileged-service-adapter
  (make-parameter
   unavailable-adapter
   (lambda (value)
     (unless (privileged-service-adapter? value)
       (raise-argument-error
        'current-privileged-service-adapter
        "privileged-service-adapter?"
        value))
     (unless (symbol? (privileged-service-adapter-name value))
       (raise-arguments-error
        'current-privileged-service-adapter
        "adapter name must be a symbol"))
     (unless (and (list? (privileged-service-adapter-capabilities value))
                  (andmap symbol?
                          (privileged-service-adapter-capabilities value)))
       (raise-arguments-error
        'current-privileged-service-adapter
        "adapter capabilities must be a list of symbols"))
     (for ([operation (in-list '(status start stop reload))]
           [procedure (in-list
                       (list (privileged-service-adapter-status value)
                             (privileged-service-adapter-start value)
                             (privileged-service-adapter-stop value)
                             (privileged-service-adapter-reload value)))]
           [arity (in-list '(1 2 1 2))])
       (unless (and (procedure? procedure)
                    (procedure-arity-includes? procedure arity))
         (raise-arguments-error
          'current-privileged-service-adapter
          "adapter operation has the wrong procedure arity"
          "operation" operation
          "expected arity" arity)))
     value)))

(define (privileged-service-capabilities)
  (privileged-service-adapter-capabilities
   (current-privileged-service-adapter)))

(define (validate-service-id who service-id)
  (define length
    (cond
      [(symbol? service-id) (string-length (symbol->string service-id))]
      [(string? service-id) (string-length service-id)]
      [else #f]))
  (unless (and length
               (positive? length)
               (<= length max-service-id-length))
    (raise-argument-error
     who
     "(or/c symbol? (and/c non-empty-string? string-length-at-most-256?))"
     service-id)))

(define (validate-configuration who configuration)
  (unless (bytes? configuration)
    (raise-argument-error who "bytes?" configuration))
  (when (> (bytes-length configuration) max-configuration-size)
    (raise-arguments-error
     who
     "configuration exceeds the privileged-service limit"
     "length" (bytes-length configuration)
     "maximum" max-configuration-size))
  ;; Do not let a caller mutate sensitive configuration after the adapter has
  ;; accepted it. `bytes->immutable-bytes` avoids a copy when it is already
  ;; immutable and otherwise snapshots the exact bytes at this boundary.
  (bytes->immutable-bytes configuration))

(define (validate-state who state)
  (unless (privileged-service-state? state)
    (error who "native adapter returned a non-state result"))
  (unless (symbol? (privileged-service-state-state state))
    (error who "native adapter returned a state with a non-symbol lifecycle"))
  (define detail (privileged-service-state-detail state))
  (unless (or (not detail)
              (and (string? detail)
                   (<= (string-length detail) max-state-detail-length)))
    (error who "native adapter returned invalid or oversized state detail"))
  (unless (exact-nonnegative-integer?
           (privileged-service-state-revision state))
    (error who "native adapter returned an invalid state revision"))
  state)

(define (privileged-service-status service-id)
  (validate-service-id 'privileged-service-status service-id)
  (validate-state
   'privileged-service-status
   ((privileged-service-adapter-status
     (current-privileged-service-adapter))
    service-id)))

(define (privileged-service-start! service-id configuration)
  (validate-service-id 'privileged-service-start! service-id)
  (define snapshot
    (validate-configuration 'privileged-service-start! configuration))
  (validate-state
   'privileged-service-start!
   ((privileged-service-adapter-start
     (current-privileged-service-adapter))
    service-id
    snapshot)))

(define (privileged-service-stop! service-id)
  (validate-service-id 'privileged-service-stop! service-id)
  (validate-state
   'privileged-service-stop!
   ((privileged-service-adapter-stop
     (current-privileged-service-adapter))
    service-id)))

(define (privileged-service-reload! service-id configuration)
  (validate-service-id 'privileged-service-reload! service-id)
  (define snapshot
    (validate-configuration 'privileged-service-reload! configuration))
  (validate-state
   'privileged-service-reload!
   ((privileged-service-adapter-reload
     (current-privileged-service-adapter))
    service-id
    snapshot)))
