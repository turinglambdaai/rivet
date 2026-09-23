#lang racket/base

(require rackunit
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define entered (make-semaphore 0))
(define release (make-semaphore 0))

(define-rpc (blocked : Int64)
  (semaphore-post entered)
  (semaphore-wait release)
  11)

(define-rpc (echo-int [value Int64] : Int64)
  value)

(define (read-frame/timeout in [seconds 2])
  (unless (sync/timeout seconds in)
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  (read-frame in))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-result (make-channel))
(define server-thread
  (thread
   (lambda ()
     (channel-put
      server-result
      (with-handlers ([exn? values])
        (serve server-in server-out)
        'completed)))))

(check-equal? (frame-type (read-frame/timeout client-in)) message:hello)

;; Keep request 100 live so a second Request with the same id is unambiguously
;; a duplicate. Waiting for the RPC body to signal entry proves the original is
;; already present in the pending table before the duplicate arrives.
(write-frame
 (frame message:request 100 (encode-value (list "blocked")))
 client-out)
(check-not-false (sync/timeout 2 entered))

;; A duplicate id cannot be addressed independently on the wire. In particular,
;; a malformed duplicate must not produce an Error with id 100, because native
;; clients would consume that Error as the terminal result of the original
;; request. The duplicate is discarded before its payload is decoded.
(write-frame (frame message:request 100 #"\xff") client-out)
(check-false (sync/timeout 0.2 client-in))

;; Releasing the original produces the one and only terminal frame for id 100.
(semaphore-post release)
(define original-response (read-frame/timeout client-in))
(check-equal? (frame-type original-response) message:response)
(check-equal? (frame-id original-response) 100)
(check-equal? (decode-value (frame-payload original-response)) 11)
(check-false (sync/timeout 0.1 client-in))

;; The connection remains usable and a different id behaves normally.
(write-frame
 (frame message:request 101 (encode-value (list "echo-int" 42)))
 client-out)
(define after-duplicate (read-frame/timeout client-in))
(check-equal? (frame-type after-duplicate) message:response)
(check-equal? (frame-id after-duplicate) 101)
(check-equal? (decode-value (frame-payload after-duplicate)) 42)

(write-frame (frame message:shutdown 0 #"") client-out)
(check-equal? (sync/timeout 2 server-result) 'completed)
(thread-wait server-thread)
