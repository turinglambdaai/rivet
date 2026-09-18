#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-event progress)

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define-rpc (work [value Int64] : Int64)
  (progress value)
  (add1 value))

(check-equal?
 (rpc-schema)
 (list
  (hasheq 'name "increment"
          'arguments (list (hasheq 'name "value" 'type "Int64"))
          'result "Int64")
  (hasheq 'name "work"
          'arguments (list (hasheq 'name "value" 'type "Int64"))
          'result "Int64")))

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

(write-frame
 (frame message:request
        2
        (encode-value (list "work" 7)))
 client-out)

(define event (read-frame client-in))
(check-equal? (frame-type event) message:event)
(check-equal? (decode-value (frame-payload event))
              (list "progress" 7))

(define work-response (read-frame client-in))
(check-equal? (frame-type work-response) message:response)
(check-equal? (frame-id work-response) 2)
(check-equal? (decode-value (frame-payload work-response)) 8)

(write-frame
 (frame message:request
        3
        (encode-value (list "increment" "wrong-type")))
 client-out)
(define type-error (read-frame client-in))
(check-equal? (frame-type type-error) message:error)
(check-equal? (frame-id type-error) 3)
(check-true (string? (decode-value (frame-payload type-error))))

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
