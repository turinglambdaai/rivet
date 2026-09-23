#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-event state-backpressure-progress : Int64)
(define-state state-backpressure-counter : Int64 0)

(define-rpc (state-backpressure-fill : Void)
  ;; Once the Event has entered the writer, keep this worker alive without
  ;; producing a Response. The test can then fill the one-frame queue from the
  ;; reader and deterministically block a later State Event.
  (state-backpressure-progress 1)
  (sync never-evt))

(define (read-frame/timeout in [seconds 2])
  (define result (make-channel))
  (thread (lambda () (channel-put result (read-frame in))))
  (define value (sync/timeout seconds result))
  (unless value
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  value)

(define (wait-until predicate [seconds 2])
  (define deadline (+ (current-inexact-milliseconds) (* seconds 1000.0)))
  (let loop ()
    (cond
      [(predicate) #t]
      [(>= (current-inexact-milliseconds) deadline) #f]
      [else
       (sleep 0.005)
       (loop)])))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe 1))
(define server-result (make-channel))
(define server-thread
  (thread
   (lambda ()
     (channel-put
      server-result
      (with-handlers ([exn? values])
        (serve server-in server-out #:max-outgoing-frames 1)
        'completed)))))

(define hello (read-frame/timeout client-in))
(check-equal? (frame-type hello) message:hello)

;; Block the writer on the first byte of an Event while leaving the reader free.
(write-frame
 (frame message:request
        1
        (encode-value (list "state-backpressure-fill")))
 client-out)
(check-true
 (wait-until (lambda () (= (pipe-content-length client-in) 1))))

;; The reader handles this rejection synchronously. When it returns from send!,
;; the one-frame output queue is full behind the blocked writer, so the next
;; State Event must wait for transport capacity.
(write-frame
 (frame message:request
        2
        (encode-value (list "state-backpressure-missing")))
 client-out)
(write-frame
 (frame message:request
        3
        (encode-value
         (list "$state/set" "state-backpressure-counter" 1)))
 client-out)

;; Observe the raw cell only to know that request 3 reached the point after
;; commit but before its blocked Event send. This deliberately bypasses
;; state-ref's lock so the test can distinguish the old locking behavior.
(check-true
 (wait-until
  (lambda ()
    (= (unbox (state-info-cell state-backpressure-counter)) 1))))

;; Output backpressure must not hold the State data lock. A pure Racket reader
;; should see the committed value immediately even while the setter is blocked
;; waiting to enqueue the reserved $state Event.
(define ref-result (make-channel))
(thread
 (lambda ()
   (channel-put ref-result (state-ref state-backpressure-counter))))
(check-equal? (sync/timeout 0.2 ref-result) 1)

;; A second setter may be dispatched, but it must stay behind the first setter's
;; private update-order lock until value 1's Event is admitted. This preserves
;; State/Event order without making state-ref wait on the transport.
(write-frame
 (frame message:request
        4
        (encode-value
         (list "$state/set" "state-backpressure-counter" 2)))
 client-out)
(check-true
 (wait-until (lambda () (zero? (pipe-content-length server-in)))))
(check-false
 (wait-until
  (lambda ()
    (= (unbox (state-info-cell state-backpressure-counter)) 2))
  0.2))

;; Drain the stalled transport. Worker scheduling can interleave the two State
;; Responses, but the reserved State Events themselves must remain 1 then 2.
(define frames
  (for/list ([i (in-range 6)])
    (read-frame/timeout client-in)))

(define state-event-values
  (for/list ([f (in-list frames)]
             #:when (= (frame-type f) message:event)
             #:do [(define payload (decode-value (frame-payload f)))]
             #:when (and (pair? payload)
                         (equal? (car payload) "$state")))
    (cadr (cadr payload))))
(check-equal? state-event-values '(1 2))

(define response-ids
  (for/list ([f (in-list frames)]
             #:when (= (frame-type f) message:response))
    (frame-id f)))
(check-not-false (member 3 response-ids))
(check-not-false (member 4 response-ids))
(check-equal? (state-ref state-backpressure-counter) 2)

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)
