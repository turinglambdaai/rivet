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

(define (start-server/result in out #:max-outgoing-frames [max-outgoing-frames 1])
  (define result (make-channel))
  (define server-thread
    (thread
     (lambda ()
       (channel-put
        result
        (with-handlers ([exn? values])
          (serve in out #:max-outgoing-frames max-outgoing-frames)
          'completed)))))
  (values server-thread result))

(define (write-unknown-request out id)
  (write-frame
   (frame message:request
          id
          (encode-value (list (format "missing-~a" id))))
   out))

;; A one-frame response queue plus a one-byte output pipe makes backpressure
;; deterministic: the writer blocks on the first Error, the next Error occupies
;; the queue, and the reader blocks while trying to enqueue the third Error.
(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe 1))
(define-values (server-thread server-result)
  (start-server/result server-in server-out #:max-outgoing-frames 1))

(define hello (read-frame/timeout client-in))
(check-equal? (frame-type hello) message:hello)

(write-unknown-request client-out 200)
(check-true
 (wait-until (lambda () (= (pipe-content-length client-in) 1))))

(write-unknown-request client-out 201)
(write-unknown-request client-out 202)
(check-true
 (wait-until (lambda () (zero? (pipe-content-length server-in)))))

;; Request 202 is now blocked while enqueueing its Error. Request 203 must stay
;; unread until output capacity is released; with an unbounded queue this pipe
;; would drain immediately and the assertion would fail.
(write-unknown-request client-out 203)
(check-false
 (wait-until (lambda () (zero? (pipe-content-length server-in))) 0.2))
(check-true (> (pipe-content-length server-in) 0))

(for ([expected-id (in-list '(200 201 202 203))])
  (define response (read-frame/timeout client-in))
  (check-equal? (frame-type response) message:error)
  (check-equal? (frame-id response) expected-id))

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
