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
;; the application/native adapter rather than becoming part of RVT1.
(struct privileged-service-state (state detail revision)
  #:transparent)

(struct privileged-service-adapter
  (name capabilities status start stop reload)
  #:transparent)

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
     value)))

(define (privileged-service-capabilities)
  (privileged-service-adapter-capabilities
   (current-privileged-service-adapter)))

(define (validate-service-id who service-id)
  (unless (or (symbol? service-id)
              (and (string? service-id) (positive? (string-length service-id))))
    (raise-argument-error who "(or/c symbol? non-empty-string?)" service-id)))

(define (validate-configuration who configuration)
  (unless (bytes? configuration)
    (raise-argument-error who "bytes?" configuration)))

(define (privileged-service-status service-id)
  (validate-service-id 'privileged-service-status service-id)
  ((privileged-service-adapter-status
    (current-privileged-service-adapter))
   service-id))

(define (privileged-service-start! service-id configuration)
  (validate-service-id 'privileged-service-start! service-id)
  (validate-configuration 'privileged-service-start! configuration)
  ((privileged-service-adapter-start
    (current-privileged-service-adapter))
   service-id
   configuration))

(define (privileged-service-stop! service-id)
  (validate-service-id 'privileged-service-stop! service-id)
  ((privileged-service-adapter-stop
    (current-privileged-service-adapter))
   service-id))

(define (privileged-service-reload! service-id configuration)
  (validate-service-id 'privileged-service-reload! service-id)
  (validate-configuration 'privileged-service-reload! configuration)
  ((privileged-service-adapter-reload
    (current-privileged-service-adapter))
   service-id
   configuration))
