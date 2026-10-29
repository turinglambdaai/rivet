#lang racket/base

(require rackunit
         racket/file
         racket/list
         rivet/backend
         rivet/protocol
         (submod "../../examples/taskboard/app/backend.rkt" test-support)
         "../../examples/taskboard/app/store.rkt")

;; This test follows real RVT1 requests, including success/failure responses,
;; rather than calling the persistence helper in isolation.
(define root (make-temporary-file "rivet-board-rpc-~a" 'directory))
(define path (build-path root "profile" "tasks.rktd"))
(restore-board-from-store! path)

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define worker (thread (lambda () (serve server-in server-out))))
(check-equal? (frame-type (read-frame client-in)) message:hello)
(define next-request-id 1)

(define (rpc name . arguments)
  (define id next-request-id)
  (set! next-request-id (add1 next-request-id))
  (write-frame
   (frame message:request id (encode-value (cons name arguments)))
   client-out)
  (let loop ()
    (define response (read-frame client-in))
    (cond
      [(= (frame-type response) message:event) (loop)]
      [(not (= (frame-id response) id))
       (error 'taskboard-rpc-test "unexpected response id: ~a" (frame-id response))]
      [(= (frame-type response) message:error)
       (values #f (decode-value (frame-payload response)))]
      [else (values (decode-value (frame-payload response)) #f)])))

(define-values (before before-error) (rpc "get-task" 2))
(check-false before-error)
(check-equal? (second before) "Make a backend change")
(define-values (saved save-error)
  (rpc "update-task" 2 "Durable title" "Saved after explicit apply." "active"))
(check-false save-error)
(check-equal? (second saved) "Durable title")
(check-equal? (second (first (read-taskboard-rows path)))
              "Read the architecture guide")
(check-equal? (second (second (read-taskboard-rows path)))
              "Durable title")

;; This mimics backend re-initialization with the *same* isolated user profile.
;; No native host or live product preferences are touched.
(reset-reference-state!)
(restore-board-from-store! path)
(define-values (restored restore-error) (rpc "get-task" 2))
(check-false restore-error)
(check-equal? (second restored) "Durable title")

;; Make the configured destination a directory: an atomic replacement must
;; fail, the RPC must report failure, and memory must retain the prior title.
(define blocked (build-path root "blocked"))
(make-directory blocked)
(restore-board-from-store! blocked)
(define-values (attempt error-message)
  (rpc "update-task" 2 "Must not appear" "Unwritable save" "active"))
(check-false attempt)
(check-true (string? error-message))
(define-values (unchanged unchanged-error) (rpc "get-task" 2))
(check-false unchanged-error)
(check-equal? (second unchanged) "Make a backend change")
(check-equal? (second (second (read-taskboard-rows path)))
              "Durable title")

;; Malformed data fails closed instead of destructively resetting the store.
(call-with-output-file
 path
 (lambda (out) (display "(rivet-taskboard-store-v9 ())" out))
 #:exists 'truncate)
(check-exn #rx"invalid or unsupported store version"
           (lambda () (restore-board-from-store! path)))
(check-true (file-exists? path))

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait worker)
(restore-board-from-store! #f)
(delete-directory/files root)
