#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))

(define server-thread
  (thread (lambda () (serve server-in server-out))))

(define hello (read-frame client-in))
(check-equal? (frame-type hello) message:hello)
(check-equal? (decode-value (frame-payload hello))
              (list "rivet" protocol-version))

(write-frame
 (frame message:request
        1
        (encode-value (list "increment" 41)))
 client-out)

(define response (read-frame client-in))
(check-equal? (frame-type response) message:response)
(check-equal? (frame-id response) 1)
(check-equal? (decode-value (frame-payload response)) 42)

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
