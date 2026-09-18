#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-event progress)
(define-state counter : Int64 10)

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define-rpc (work [value Int64] : Int64)
  (progress value)
  (add1 value))

(define-rpc (wait-forever : Void)
  (sync never-evt))

(check-equal?
 (rpc-schema)
 (list
  (hasheq 'name "increment"
          'arguments (list (hasheq 'name "value" 'type "Int64"))
          'result "Int64")
  (hasheq 'name "wait-forever"
          'arguments '()
          'result "Void")
  (hasheq 'name "work"
          'arguments (list (hasheq 'name "value" 'type "Int64"))
          'result "Int64")))

(check-equal? (state-schema)
              (list (hasheq 'name "counter" 'type "Int64")))
(check-equal? (state-ref counter) 10)
(check-exn exn:fail?
           (lambda () (state-set! counter "wrong-type")))

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

(write-frame
 (frame message:request
        4
        (encode-value (list "wait-forever")))
 client-out)
(write-frame (frame message:cancel 4 #"") client-out)
(define cancelled (read-frame client-in))
(check-equal? (frame-type cancelled) message:error)
(check-equal? (frame-id cancelled) 4)
(check-equal? (decode-value (frame-payload cancelled)) "request cancelled")

(write-frame
 (frame message:request
        5
        (encode-value (list "$state/get" "counter")))
 client-out)
(define initial-state (read-frame client-in))
(check-equal? (frame-type initial-state) message:response)
(check-equal? (frame-id initial-state) 5)
(check-equal? (decode-value (frame-payload initial-state)) 10)

(write-frame
 (frame message:request
        6
        (encode-value (list "$state/set" "counter" 11)))
 client-out)
(define state-event (read-frame client-in))
(check-equal? (frame-type state-event) message:event)
(check-equal? (decode-value (frame-payload state-event))
              (list "$state" (list "counter" 11)))
(define state-response (read-frame client-in))
(check-equal? (frame-type state-response) message:response)
(check-equal? (frame-id state-response) 6)
(check-equal? (decode-value (frame-payload state-response)) 11)
(check-equal? (state-ref counter) 11)

(write-frame
 (frame message:request
        7
        (encode-value (list "$state/set" "counter" "wrong-type")))
 client-out)
(define state-type-error (read-frame client-in))
(check-equal? (frame-type state-type-error) message:error)
(check-equal? (frame-id state-type-error) 7)
(check-equal? (state-ref counter) 11)

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
