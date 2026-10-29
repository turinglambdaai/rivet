#lang racket/base

(require rackunit
         racket/file
         racket/list
         rivet/backend
         rivet/protocol
         "../app/backend.rkt"
         (submod "../app/backend.rkt" test-support)
         "../app/task-store.rkt")

;; Prove the exact startup initializer used by the native fd entrypoint
;; reloads a committed snapshot on a second real RVT1 pipe session.
;; serve-fds requires OS descriptors, so this test uses serve with ports.
(define root (make-temporary-file "rivet-taskboard-relaunch~a" 'directory))
(define original-env (getenv "RIVET_TASKBOARD_DATA_DIR"))
(define next-request-id 1)

(define (open-session)
  (define-values (server-in client-out) (make-pipe))
  (define-values (client-in server-out) (make-pipe))
  (define worker
    (thread (lambda ()
              (initialize-taskboard!)
              (serve server-in server-out))))
  (check-equal? (frame-type (read-frame client-in)) message:hello)
  (values client-in client-out worker))

(define (rpc-call input output name . args)
  (define id next-request-id)
  (set! next-request-id (add1 next-request-id))
  (write-frame (frame message:request id (encode-value (cons name args))) output)
  (let loop ()
    (define reply (read-frame input))
    (cond
      [(= (frame-type reply) message:event) (loop)]
      [(= (frame-id reply) id)
       (when (= (frame-type reply) message:error)
         (error 'rpc-call "backend rejected ~a: ~e" name
                (decode-value (frame-payload reply))))
       (decode-value (frame-payload reply))]
      [else (error 'rpc-call "unexpected RVT1 reply id")])))

(define (close-session input output worker)
  (write-frame (frame message:shutdown 0 #"") output)
  (thread-wait worker)
  (close-input-port input)
  (close-output-port output))

(dynamic-wind
  (lambda () (putenv "RIVET_TASKBOARD_DATA_DIR" (path->string root)))
  (lambda ()
    ;; Keep this deterministic even if raco test loads multiple files into
    ;; one Racket process with an already-instantiated backend module.
    (reset-reference-state!)
    (let-values ([(input output worker) (open-session)])
      (define first-row (first (rpc-call input output "list-tasks")))
      (define saved (rpc-call input output "update-task"
                              1 "Survives process relaunch"
                              "real RVT1 operation" "active"))
      (check-equal? (list-ref first-row 1) "Read the architecture guide")
      (check-equal? (list-ref saved 1) "Survives process relaunch")
      (close-session input output worker))
    (let ([snapshot (read-task-snapshot root)])
      (check-not-false snapshot)
      (check-equal? (list-ref (first (vector-ref snapshot 1)) 1)
                    "Survives process relaunch"))
    ;; Throw away the in-memory State and launch a second server. This is
    ;; not a duplicate call to the serializer; startup must load the file.
    (reset-reference-state!)
    (let-values ([(input output worker) (open-session)])
      (define after-restart (first (rpc-call input output "list-tasks")))
      (check-equal? (list-ref after-restart 1) "Survives process relaunch")
      (check-equal? (list-ref after-restart 2) "real RVT1 operation")
      (close-session input output worker)))
  (lambda ()
    (putenv "RIVET_TASKBOARD_DATA_DIR" (or original-env ""))
    (delete-directory/files root)))
