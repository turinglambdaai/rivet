#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

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

(define (start-server/result in
                             out
                             #:max-pending-requests [max-pending-requests 1024]
                             #:max-outgoing-frames [max-outgoing-frames 1])
  (define result (make-channel))
  (define server-thread
    (thread
     (lambda ()
       (channel-put
        result
        (with-handlers ([exn? values])
          (serve in
                 out
                 #:max-pending-requests max-pending-requests
                 #:max-outgoing-frames max-outgoing-frames)
          'completed)))))
  (values server-thread result))

(define (write-unknown-request out id)
  (write-frame
   (frame message:request
          id
          (encode-value (list (format "missing-~a" id))))
   out))

(define (write-missing-state-request out id)
  (write-frame
   (frame message:request
          id
          (encode-value (list "$state/get" (format "missing-state-~a" id))))
   out))

;; A one-frame response queue plus a one-byte output pipe makes backpressure
;; deterministic. Request 200 blocks the writer, and request 201 fills the only
;; queued response slot.
(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe 1))
(define-values (server-thread server-result)
  (start-server/result server-in
                       server-out
                       #:max-pending-requests 1
                       #:max-outgoing-frames 1))

(define hello (read-frame/timeout client-in))
(check-equal? (frame-type hello) message:hello)

(write-unknown-request client-out 200)
(check-true
 (wait-until (lambda () (= (pipe-content-length client-in) 1))))

(write-unknown-request client-out 201)
(check-true
 (wait-until (lambda () (zero? (pipe-content-length server-in)))))

;; Built-in State requests are admitted before lookup runs in a worker. Request
;; 300 therefore occupies the only pending slot and then blocks while trying to
;; enqueue its terminal Error behind the full output queue.
(write-missing-state-request client-out 300)
(check-true
 (wait-until (lambda () (zero? (pipe-content-length server-in)))))
(sleep 0.05)

;; A claimed terminal request must remain counted as pending until its frame is
;; admitted to the output queue. Request 301 is therefore rejected for overload
;; by the reader itself, which then blocks on the same full output queue.
(write-missing-state-request client-out 301)
(check-true
 (wait-until (lambda () (zero? (pipe-content-length server-in)))))
(sleep 0.05)

;; Because the reader is blocked enqueueing request 301's overload Error, this
;; next request must stay unread. An unbounded output queue, or releasing request
;; 300's pending slot before enqueue succeeds, would let the pipe drain.
(write-unknown-request client-out 202)
(check-false
 (wait-until (lambda () (zero? (pipe-content-length server-in))) 0.2))
(check-true (> (pipe-content-length server-in) 0))

;; Drain the transport. The two blocked producers (request 300's worker and the
;; reader rejecting 301) can race for the newly available queue slot, so assert
;; by request id instead of depending on their relative order.
(define observed (make-hash))
(for ([i (in-range 5)])
  (define response (read-frame/timeout client-in))
  (check-equal? (frame-type response) message:error)
  (hash-set! observed
             (frame-id response)
             (decode-value (frame-payload response))))

(for ([id (in-list '(200 201 300 301 202))])
  (check-true (hash-has-key? observed id)))
(check-regexp-match #rx"unknown state" (hash-ref observed 300))
(check-regexp-match #rx"too many pending requests" (hash-ref observed 301))

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)

;; Writer failure must terminate `serve` even when the reader has no input.
;; Otherwise a broken native transport could leave the backend blocked forever
;; in read-frame while producers accumulate behind a dead writer.
(define-values (failure-in failure-client-out) (make-pipe))
(define broken-out (open-output-bytes))
(close-output-port broken-out)
(define-values (failure-thread failure-result)
  (start-server/result failure-in broken-out #:max-outgoing-frames 1))
(define failure (sync/timeout 2 failure-result))
(check-not-false failure)
(check-true (exn? failure))
(thread-wait failure-thread)
(close-output-port failure-client-out)

;; Configuration rejects a zero-capacity queue instead of creating a server
;; that can never enqueue Hello.
(check-exn
 exn:fail:contract?
 (lambda ()
   (serve (open-input-bytes #"")
          (open-output-bytes)
          #:max-outgoing-frames 0)))
