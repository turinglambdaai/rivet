#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-event progress : Int64)
(define-state counter : Int64 10)

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define-rpc (oversized-result : Any)
  ;; The root List plus max-value-nodes children exceeds the total node budget.
  (make-list max-value-nodes (void)))

(define-rpc (work [value Int64] : Int64)
  (progress value)
  (add1 value))

(define-rpc (wait-forever : Void)
  (sync never-evt))

(define (read-frame/timeout in [seconds 2])
  (define result (make-channel))
  (thread (lambda () (channel-put result (read-frame in))))
  (define value (sync/timeout seconds result))
  (unless value
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  value)

(check-equal?
 (rpc-schema)
 (list
  (hasheq 'name "increment"
          'arguments (list (hasheq 'name "value" 'type "Int64"))
          'result "Int64")
  (hasheq 'name "oversized-result"
          'arguments '()
          'result "Any")
  (hasheq 'name "wait-forever"
          'arguments '()
          'result "Void")
  (hasheq 'name "work"
          'arguments (list (hasheq 'name "value" 'type "Int64"))
          'result "Int64")))

(check-equal? (event-schema)
              (list (hasheq 'name "progress" 'type "Int64")))
(check-exn #rx"value does not match declared Rivet type"
           (lambda () (progress "wrong-type")))

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

;; Request registration happens synchronously before the server reads the next
;; frame, so an immediately following Cancel deterministically finds request 4.
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

;; Response encoding can fail after application code has completed. The request
;; must stay pending until encoding succeeds so the worker can convert an
;; encoding failure into a request-scoped Error rather than silently dropping
;; the terminal response.
(write-frame
 (frame message:request
        8
        (encode-value (list "oversized-result")))
 client-out)
(define encoding-error (read-frame/timeout client-in))
(check-equal? (frame-type encoding-error) message:error)
(check-equal? (frame-id encoding-error) 8)
(check-regexp-match #rx"node count exceeds Rivet protocol limit"
                    (decode-value (frame-payload encoding-error)))

;; The failed response released its pending slot and left the server usable.
(write-frame
 (frame message:request
        9
        (encode-value (list "increment" 9)))
 client-out)
(define after-encoding-error (read-frame/timeout client-in))
(check-equal? (frame-type after-encoding-error) message:response)
(check-equal? (frame-id after-encoding-error) 9)
(check-equal? (decode-value (frame-payload after-encoding-error)) 10)

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)

;; Resource limits and malformed application requests are request-local. They
;; must not terminate the embedded server or leak a pending slot.
(define-values (limited-server-in limited-client-out) (make-pipe))
(define-values (limited-client-in limited-server-out) (make-pipe))
(define limited-server-thread
  (thread
   (lambda ()
     (serve limited-server-in
            limited-server-out
            #:max-pending-requests 1))))

(check-equal? (frame-type (read-frame limited-client-in)) message:hello)

(write-frame
 (frame message:request
        100
        (encode-value (list "wait-forever")))
 limited-client-out)
(write-frame
 (frame message:request
        101
        (encode-value (list "increment" 1)))
 limited-client-out)
(define overload (read-frame limited-client-in))
(check-equal? (frame-type overload) message:error)
(check-equal? (frame-id overload) 101)
(check-regexp-match #rx"too many pending requests"
                    (decode-value (frame-payload overload)))

(write-frame (frame message:cancel 100 #"") limited-client-out)
(define limited-cancelled (read-frame limited-client-in))
(check-equal? (frame-type limited-cancelled) message:error)
(check-equal? (frame-id limited-cancelled) 100)
(check-equal? (decode-value (frame-payload limited-cancelled))
              "request cancelled")

;; Cancelling request 100 freed the only pending slot.
(write-frame
 (frame message:request
        102
        (encode-value (list "increment" 1)))
 limited-client-out)
(define after-cancel (read-frame limited-client-in))
(check-equal? (frame-type after-cancel) message:response)
(check-equal? (frame-id after-cancel) 102)
(check-equal? (decode-value (frame-payload after-cancel)) 2)

;; Unknown RPCs are rejected without killing the server.
(write-frame
 (frame message:request
        103
        (encode-value (list "does-not-exist")))
 limited-client-out)
(define unknown-rpc (read-frame limited-client-in))
(check-equal? (frame-type unknown-rpc) message:error)
(check-equal? (frame-id unknown-rpc) 103)
(check-regexp-match #rx"unknown RPC"
                    (decode-value (frame-payload unknown-rpc)))

(write-frame
 (frame message:request
        104
        (encode-value (list "increment" 9)))
 limited-client-out)
(define after-error (read-frame limited-client-in))
(check-equal? (frame-type after-error) message:response)
(check-equal? (frame-id after-error) 104)
(check-equal? (decode-value (frame-payload after-error)) 10)

(write-frame (frame message:shutdown 0 #"") limited-client-out)
(thread-wait limited-server-thread)
