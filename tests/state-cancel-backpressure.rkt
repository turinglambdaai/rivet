#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-event state-cancel-progress : Int64)
(define-state state-cancel-counter : Int64 0)

(define-rpc (state-cancel-fill : Void)
  ;; Put one Event into the writer, then keep the request alive without adding a
  ;; terminal frame. With a one-byte output pipe this stalls the writer while
  ;; the reader remains free to fill the one-frame outgoing queue.
  (state-cancel-progress 1)
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

;; Block the writer on the first byte of an Event.
(write-frame
 (frame message:request
        1
        (encode-value (list "state-cancel-fill")))
 client-out)
(check-true
 (wait-until (lambda () (= (pipe-content-length client-in) 1))))

;; Fill the one-frame output queue synchronously from the reader. Request 3 can
;; then commit its State cell, but its reserved $state Event cannot enter the
;; full queue yet.
(write-frame
 (frame message:request
        2
        (encode-value (list "state-cancel-missing")))
 client-out)
(write-frame
 (frame message:request
        3
        (encode-value (list "$state/set" "state-cancel-counter" 1)))
 client-out)
(check-true
 (wait-until
  (lambda ()
    (= (unbox (state-info-cell state-cancel-counter)) 1))))

;; Cancellation after commit must not kill the worker before its already-
;; committed State update has an Event admitted to the outgoing queue. The
;; cancellation terminal remains pending behind that Event.
(write-frame (frame message:cancel 3 #"") client-out)
(check-true
 (wait-until (lambda () (zero? (pipe-content-length server-in)))))
(check-equal? (state-ref state-cancel-counter) 1)

;; Drain the transport. The committed State Event must exist and must precede
;; request 3's cancelled Error. Old behavior killed the setter here, producing
;; the Error but permanently losing the State Event.
(define frames
  (for/list ([i (in-range 4)])
    (read-frame/timeout client-in)))

(define state-event-index
  (for/first ([f (in-list frames)]
              [i (in-naturals)]
              #:when (= (frame-type f) message:event)
              #:do [(define payload (decode-value (frame-payload f)))]
              #:when (and (pair? payload)
                          (equal? (car payload) "$state")
                          (equal? (cadr payload)
                                  (list "state-cancel-counter" 1))))
    i))
(define cancel-error-index
  (for/first ([f (in-list frames)]
              [i (in-naturals)]
              #:when (and (= (frame-type f) message:error)
                          (= (frame-id f) 3)))
    i))
(check-not-false state-event-index)
(check-not-false cancel-error-index)
(check-true (< state-event-index cancel-error-index))
(check-equal? (decode-value (frame-payload (list-ref frames cancel-error-index)))
              "request cancelled")
(check-equal? (state-ref state-cancel-counter) 1)

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)