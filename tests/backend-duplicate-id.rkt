#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define original-started (make-semaphore 0))
(define release-original (make-semaphore 0))

(define-rpc (duplicate-hold [value : Int64] : Int64)
  (semaphore-post original-started)
  (semaphore-wait release-original)
  value)

(define-rpc (duplicate-probe : Int64)
  7)

(define (read-frame/timeout in [seconds 2])
  (define result (make-channel))
  (thread (lambda () (channel-put result (read-frame in))))
  (define value (sync/timeout seconds result))
  (unless value
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  value)

(define (write-request out id name . args)
  (write-frame
   (frame message:request
          id
          (encode-value (cons name args)))
   out))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-result (make-channel))
(define server-thread
  (thread
   (lambda ()
     (channel-put
      server-result
      (with-handlers ([exn? values])
        (serve server-in server-out)
        'completed)))))

(define hello (read-frame/timeout client-in))
(check-equal? (frame-type hello) message:hello)

;; Keep request 77 pending, then send another Request with the same id and an
;; intentionally invalid value payload. Duplicate detection must happen before
;; payload parsing: emitting an Error for the second frame would use id 77 and
;; steal the original caller's only continuation.
(write-request client-out 77 "duplicate-hold" 41)
(check-not-false (sync/timeout 2 original-started))
(write-frame (frame message:request 77 #"\xff") client-out)

;; A later independent request provides deterministic ordering. The reader sees
;; the duplicate frame before request 78, so any duplicate Error would reach the
;; writer before this Response. First-request-wins semantics therefore require
;; request 78 to be the first terminal frame we observe.
(write-request client-out 78 "duplicate-probe")
(define probe-response (read-frame/timeout client-in))
(check-equal? (frame-type probe-response) message:response)
(check-equal? (frame-id probe-response) 78)
(check-equal? (decode-value (frame-payload probe-response)) 7)

;; Releasing the original request produces its one and only terminal frame.
(semaphore-post release-original)
(define original-response (read-frame/timeout client-in))
(check-equal? (frame-type original-response) message:response)
(check-equal? (frame-id original-response) 77)
(check-equal? (decode-value (frame-payload original-response)) 41)

;; Once request 77 has released its pending entry, the id can be reused by a
;; later request normally.
(write-request client-out 77 "duplicate-probe")
(define reused-response (read-frame/timeout client-in))
(check-equal? (frame-type reused-response) message:response)
(check-equal? (frame-id reused-response) 77)
(check-equal? (decode-value (frame-payload reused-response)) 7)

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)
