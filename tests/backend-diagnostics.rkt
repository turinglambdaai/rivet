#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define result-writer-called? (box #f))
(define exit-writer-called? (box #f))
(define diagnostic-records (box '()))
(define diagnostic-lock (make-semaphore 1))

;; The embedded default is deliberately silent. Writing to stderr can lazily
;; allocate a console for a Windows GUI-subsystem host.
(define default-output (open-output-string))
(parameterize ([current-error-port default-output])
  ((current-rivet-diagnostic-sink) (hasheq 'event "must-not-print")))
(check-equal? (get-output-string default-output) "")

(define (capture-diagnostic! record)
  (call-with-semaphore
   diagnostic-lock
   (lambda ()
     (set-box! diagnostic-records
               (cons record (unbox diagnostic-records))))))

(define (diagnostic-record-exists? layer event status [request-id #f])
  (for/or ([record (in-list (unbox diagnostic-records))])
    (and (equal? (hash-ref record 'schema) "rivet.diagnostic.v1")
         (equal? (hash-ref record 'layer) layer)
         (equal? (hash-ref record 'event) event)
         (equal? (hash-ref record 'status) status)
         (or (not request-id)
             (= (hash-ref record 'request_id) request-id)))))

(struct explosive-result ()
  #:property prop:custom-write
  (lambda (_ out _mode)
    (set-box! result-writer-called? #t)
    (display "EXPLOSIVE-RESULT" out)))

(struct explosive-exit ()
  #:property prop:custom-write
  (lambda (_ out _mode)
    (set-box! exit-writer-called? #t)
    (display "EXPLOSIVE-EXIT" out)))

(define-rpc (diagnostic-bad-result : Int64)
  (explosive-result))

(define-rpc (diagnostic-exit : Void)
  (exit (explosive-exit)))

(define (read-frame/timeout in [seconds 2])
  (define result (make-channel))
  (thread (lambda () (channel-put result (read-frame in))))
  (define value (sync/timeout seconds result))
  (unless value
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  value)

(define (write-request out id payload)
  (write-frame (frame message:request id payload) out))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-result (make-channel))
(define server-thread
  (thread
   (lambda ()
     (channel-put
      server-result
      (with-handlers ([exn? values])
        (serve server-in server-out #:diagnostic-sink capture-diagnostic!)
        'completed)))))

(define hello (read-frame/timeout client-in))
(check-equal? (frame-type hello) message:hello)

;; Type validation must not print an arbitrary application object merely to
;; construct the diagnostic. The Error should describe the safe value kind.
(write-request client-out 1 (encode-value (list "diagnostic-bad-result")))
(define bad-result (read-frame/timeout client-in))
(check-equal? (frame-type bad-result) message:error)
(check-equal? (frame-id bad-result) 1)
(define bad-result-message (decode-value (frame-payload bad-result)))
(check-regexp-match #rx"value does not match declared Rivet type" bad-result-message)
(check-regexp-match #rx"Unsupported" bad-result-message)
(check-false (unbox result-writer-called?))
(check-false (regexp-match? #rx"EXPLOSIVE-RESULT" bad-result-message))

;; A decoded but structurally invalid Request must not echo the full wire value.
(write-request client-out 2 (encode-value (list 123 "DO-NOT-ECHO")))
(define malformed (read-frame/timeout client-in))
(check-equal? (frame-type malformed) message:error)
(check-equal? (frame-id malformed) 2)
(define malformed-message (decode-value (frame-payload malformed)))
(check-regexp-match #rx"invalid RPC request payload" malformed-message)
(check-false (regexp-match? #rx"DO-NOT-ECHO" malformed-message))

;; Non-exception exit values are also arbitrary application objects. The
;; inherited exit handler must convert them to a fixed diagnostic without
;; invoking custom printing.
(write-request client-out 3 (encode-value (list "diagnostic-exit")))
(define exit-error (read-frame/timeout client-in))
(check-equal? (frame-type exit-error) message:error)
(check-equal? (frame-id exit-error) 3)
(define exit-message (decode-value (frame-payload exit-error)))
(check-regexp-match #rx"backend requested exit with non-exception value" exit-message)
(check-false (unbox exit-writer-called?))
(check-false (regexp-match? #rx"EXPLOSIVE-EXIT" exit-message))

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)

(check-true
 (diagnostic-record-exists? "protocol" "handshake" "success"))
(check-true
 (diagnostic-record-exists? "racket-backend" "rpc-dispatch" "failure" 3))
(check-true
 (diagnostic-record-exists? "racket-backend" "backend-exit" "success"))
(define rpc-failure
  (for/first ([record (in-list (unbox diagnostic-records))]
              #:when (and (equal? (hash-ref record 'event) "rpc-dispatch")
                          (equal? (hash-ref record 'status) "failure")
                          (= (hash-ref record 'request_id -1) 3)))
    record))
(check-equal? (hash-ref rpc-failure 'last_protocol_event) "request")
(check-false (regexp-match? #rx"EXPLOSIVE-EXIT"
                            (hash-ref rpc-failure 'message)))
