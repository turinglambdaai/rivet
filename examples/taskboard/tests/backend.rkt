#lang racket/base

(require rackunit
         racket/runtime-path
         rivet/backend
         rivet/protocol
         rivet/resources
         "../app/backend.rkt")

(define-runtime-path taskboard-root "..")

(define startup-start (current-inexact-milliseconds))
(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread
  (parameterize ([current-resource-root taskboard-root])
    (thread (lambda () (serve server-in server-out)))))

(define hello (read-frame client-in))
(check-equal? (frame-type hello) message:hello)
(define startup-elapsed (- (current-inexact-milliseconds) startup-start))
(check-true (<= startup-elapsed 5000)
            (format "backend hello exceeded 5,000 ms: ~a" startup-elapsed))

(define next-id 1)

(define (send-request name . arguments)
  (define id next-id)
  (set! next-id (add1 next-id))
  (write-frame
   (frame message:request id (encode-value (cons name arguments)))
   client-out)
  id)

(define (read-terminal id)
  (let loop ([events '()])
    (define response (read-frame client-in))
    (cond
      [(= (frame-type response) message:event)
       (loop (cons (decode-value (frame-payload response)) events))]
      [(= (frame-id response) id)
       (values response (reverse events))]
      [else
       (error 'read-terminal "unexpected response id: ~a" (frame-id response))])))

(define (call name . arguments)
  (define id (apply send-request name arguments))
  (define-values (response events) (read-terminal id))
  (when (= (frame-type response) message:error)
    (error 'call "~a" (decode-value (frame-payload response))))
  (values (decode-value (frame-payload response)) events))

(define-values (initial _) (call "list-tasks"))
(check-equal? (length initial) 3)
(check-equal? (car initial)
              (list 1
                    "Read the architecture guide"
                    "Trace native UI -> generated client -> RVT1 -> Racket."
                    "done"))

(define-values (created create-events)
  (call "create-task" "  Learn Rivet records  " "  Keep the UI native.  "))
(check-equal? (list-ref created 1) "Learn Rivet records")
(check-equal? (list-ref created 2) "Keep the UI native.")
(check-equal? (list-ref created 3) "backlog")
(check-true
 (for/or ([event (in-list create-events)])
   (equal? event (list "task-saved" created))))

(define created-id (car created))
(define-values (selected select-events) (call "select-task" created-id))
(check-equal? selected created)
(check-true
 (for/or ([event (in-list select-events)])
   (equal? event (list "$state" (list "selected-task-id" created-id)))))

(define-values (updated update-events)
  (call "update-task"
        created-id
        "Learn the generated clients"
        "Compare Swift, C++, and Kotlin."
        "active"))
(check-equal? (list-ref updated 3) "active")
(check-true
 (for/or ([event (in-list update-events)])
   (equal? event (list "task-saved" updated))))

(define-values (deleted delete-events) (call "delete-task" created-id))
(check-true deleted)
(check-true
 (for/or ([event (in-list delete-events)])
   (equal? event (list "$state" (list "selected-task-id" (void))))))

;; This proves the resource is part of executable behavior, not decorative
;; sample data that silently disappears from packaged applications.
(define-values (sample-tasks sample-events) (call "reload-sample-tasks"))
(check-equal? (length sample-tasks) 3)
(check-equal? (list-ref (car sample-tasks) 1) "Review the generated API")

;; Wait for the first progress Event before cancelling. The request must produce
;; the normal Rivet cancellation Error and must not commit its partial list.
(define generation-id (send-request "generate-demo-tasks" 1000))
(define first-progress (read-frame client-in))
(check-equal? (frame-type first-progress) message:event)
(check-equal? (car (decode-value (frame-payload first-progress)))
              "operation-progress")
(write-frame (frame message:cancel generation-id #"") client-out)
(define-values (cancelled cancellation-events) (read-terminal generation-id))
(check-equal? (frame-type cancelled) message:error)
(check-equal? (decode-value (frame-payload cancelled)) "request cancelled")

(define-values (after-cancel after-cancel-events) (call "list-tasks"))
(check-equal? after-cancel sample-tasks)

(define invalid-id (send-request "generate-demo-tasks" 1001))
(define-values (invalid invalid-events) (read-terminal invalid-id))
(check-equal? (frame-type invalid) message:error)
(check-regexp-match #rx"between 0 and 1000"
                    (decode-value (frame-payload invalid)))

;; This is a deliberately generous regression guard, not a microbenchmark.
;; The platform UIs keep their own end-to-end budgets in PERFORMANCE.md.
(define generation-start (current-inexact-milliseconds))
(define-values (generated generated-events) (call "generate-demo-tasks" 1000))
(define generation-elapsed
  (- (current-inexact-milliseconds) generation-start))
(check-equal? (length generated) 1000)
(check-true (<= generation-elapsed 5000)
            (format "1,000-row backend request exceeded 5,000 ms: ~a"
                    generation-elapsed))
(check-true (>= (length generated-events) 2))

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
