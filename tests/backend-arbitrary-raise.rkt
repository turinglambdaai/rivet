#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-rpc (raise-symbol : Void)
  (raise 'boom))

;; `exn` is the base exception type; it is not necessarily an `exn:fail?`.
(define-rpc (raise-base-exn : Void)
  (raise (exn "base exception" (current-continuation-marks))))

(define-rpc (echo-int [value Int64] : Int64)
  value)

(define (read-frame/timeout in [seconds 2])
  (define result (make-channel))
  (thread (lambda () (channel-put result (read-frame in))))
  (define value (sync/timeout seconds result))
  (unless value
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  value)

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-result (make-channel))
(define server-thread
  (thread
   (lambda ()
     (channel-put
      server-result
      (with-handlers ([exn? values])
        (serve server-in server-out #:max-pending-requests 1)
        'completed)))))

(check-equal? (frame-type (read-frame/timeout client-in)) message:hello)

(define (send-request id name . args)
  (write-frame
   (frame message:request id (encode-value (cons name args)))
   client-out))

;; Racket permits raising arbitrary values. They must still produce exactly one
;; terminal Error instead of killing the request worker and leaking its pending
;; slot forever. Do not echo the arbitrary value into the diagnostic.
(send-request 1 "raise-symbol")
(define symbol-error (read-frame/timeout client-in))
(check-equal? (frame-type symbol-error) message:error)
(check-equal? (frame-id symbol-error) 1)
(check-equal? (decode-value (frame-payload symbol-error))
              "Rivet request raised a non-exception value")

;; max-pending-requests is 1. A successful request immediately after the
;; arbitrary raise proves the failed request released the sole pending slot.
(send-request 2 "echo-int" 42)
(define after-symbol (read-frame/timeout client-in))
(check-equal? (frame-type after-symbol) message:response)
(check-equal? (frame-id after-symbol) 2)
(check-equal? (decode-value (frame-payload after-symbol)) 42)

;; Base `exn` values should preserve their bounded message even when they are
;; outside the narrower `exn:fail?` hierarchy.
(send-request 3 "raise-base-exn")
(define base-error (read-frame/timeout client-in))
(check-equal? (frame-type base-error) message:error)
(check-equal? (frame-id base-error) 3)
(check-equal? (decode-value (frame-payload base-error)) "base exception")

;; And the pending slot is reusable after that failure too.
(send-request 4 "echo-int" 7)
(define after-base (read-frame/timeout client-in))
(check-equal? (frame-type after-base) message:response)
(check-equal? (frame-id after-base) 4)
(check-equal? (decode-value (frame-payload after-base)) 7)

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)
