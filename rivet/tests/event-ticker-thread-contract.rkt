#lang racket/base

(require rackunit
         racket/list
         "../../rivet/backend.rkt"
         "../../rivet/protocol.rkt")

(define-event chart-batch : Int64)

;; With exactly one connected server a worker born outside the serve
;; reader's parameterization may publish through the active, bounded
;; writer channel; this is a deliberate public behavior change (#362).
(define start-external (make-semaphore 0))
(define external-result (make-channel))
(define external-ticker
  (thread (lambda ()
            (semaphore-wait start-external)
            (channel-put
             external-result
             (with-handlers ([exn:fail? exn-message])
               (chart-batch 11)
               'emitted)))))

(define-rpc (start-chart-ticker : Void)
  ;; RPC workers inherit the reader's event parameter. Threads spawned here
  ;; inherit it again even after the initiating request returns.
  (thread (lambda () (chart-batch 22)))
  (void))

(define (read-frame/timeout in)
  (define reply (make-channel))
  (thread (lambda () (channel-put reply (read-frame in))))
  (or (sync/timeout 2 reply)
      (error 'read-frame/timeout "timed out waiting for a backend frame")))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server (thread (lambda () (serve server-in server-out))))
(check-equal? (frame-type (read-frame/timeout client-in)) message:hello)

(semaphore-post start-external)
(check-equal? (sync/timeout 2 external-result) 'emitted)
(thread-wait external-ticker)
(define outside-event (read-frame/timeout client-in))
(check-equal? (frame-type outside-event) message:event)
(check-equal? (decode-value (frame-payload outside-event))
              (list "chart-batch" 11))

(write-frame
 (frame message:request 10 (encode-value (list "start-chart-ticker")))
 client-out)
(define first (read-frame/timeout client-in))
(define second (read-frame/timeout client-in))
(define messages (list first second))
(check-equal? (sort (map frame-type messages) <)
              (sort (list message:event message:response) <))
(define published
  (for/first ([reply (in-list messages)]
              #:when (= (frame-type reply) message:event))
    (decode-value (frame-payload reply))))
(check-equal? published (list "chart-batch" 22))
(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server)
