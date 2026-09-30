#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-record Person
  ([name : String]
   [age : Int64]
   [nickname : (Optional String)]))

(define-record Envelope
  ([owner : Person]
   [tags : (List String)]))

(define-rpc (echo-person [person : Person] : Person)
  person)

(define-rpc (wrap-person [person : Person] : Envelope)
  (Envelope person (list "taskly" "record")))

(define-state selected : Person (Person "Ada" 37 (void)))

(define ada (Person "Ada" 37 (void)))
(check-equal? (record-ref ada 'name) "Ada")
(check-equal? (record-ref ada "age") 37)
(check-true (void? (record-ref ada 'nickname)))
(check-exn exn:fail? (lambda () (record-ref ada 'missing)))

(check-equal?
 (record-schema)
 (list
  (hasheq 'name "Envelope"
          'fields
          (list (hasheq 'name "owner" 'type "Person")
                (hasheq 'name "tags" 'type "(List String)")))
  (hasheq 'name "Person"
          'fields
          (list (hasheq 'name "name" 'type "String")
                (hasheq 'name "age" 'type "Int64")
                (hasheq 'name "nickname" 'type "(Optional String)")))))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread (thread (lambda () (serve server-in server-out))))

(define hello (read-frame client-in))
(check-equal? (frame-type hello) message:hello)

;; Record stays RVT1-compatible: the raw wire value is a positional list, while
;; the Racket RPC receives a named record-value and generated clients can expose
;; a native DTO.
(write-frame
 (frame message:request
        1
        (encode-value
         (list "echo-person" (list "Ada" 37 (void)))))
 client-out)
(define echo-response (read-frame client-in))
(check-equal? (frame-type echo-response) message:response)
(check-equal? (decode-value (frame-payload echo-response))
              (list "Ada" 37 (void)))

(write-frame
 (frame message:request
        2
        (encode-value
         (list "wrap-person" (list "Ada" 37 "A"))))
 client-out)
(define wrap-response (read-frame client-in))
(check-equal? (decode-value (frame-payload wrap-response))
              (list (list "Ada" 37 "A") (list "taskly" "record")))

(write-frame
 (frame message:request
        3
        (encode-value (list "$state/get" "selected")))
 client-out)
(define state-response (read-frame client-in))
(check-equal? (decode-value (frame-payload state-response))
              (list "Ada" 37 (void)))

(write-frame
 (frame message:request
        4
        (encode-value
         (list "$state/set" "selected" (list "Grace" 44 "Amazing"))))
 client-out)
(define state-event (read-frame client-in))
(check-equal? (decode-value (frame-payload state-event))
              (list "$state" (list "selected" (list "Grace" 44 "Amazing"))))
(define state-set-response (read-frame client-in))
(check-equal? (decode-value (frame-payload state-set-response))
              (list "Grace" 44 "Amazing"))
(check-equal? (record-ref (state-ref selected) 'name) "Grace")

;; Field shape/type failures become normal request errors, not protocol errors.
(write-frame
 (frame message:request
        5
        (encode-value (list "echo-person" (list "Too" 1))))
 client-out)
(define shape-error (read-frame client-in))
(check-equal? (frame-type shape-error) message:error)
(check-true (string? (decode-value (frame-payload shape-error))))

(write-frame
 (frame message:request
        6
        (encode-value (list "echo-person" (list "Wrong" "age" (void)))))
 client-out)
(define type-error (read-frame client-in))
(check-equal? (frame-type type-error) message:error)
(check-true (string? (decode-value (frame-payload type-error))))

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
