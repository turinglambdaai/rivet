#lang racket/base

(require racket/async-channel
         racket/runtime-path
         rackunit
         "../rivet/backend.rkt")

;; The update-order registry is intentionally private so state-info keeps its
;; public four-field shape. Inspect it here to make first-use lock creation a
;; deterministic concurrency regression instead of relying on a scheduler race
;; to expose duplicate weak-hash entries.
(define-runtime-module-path-index backend-module "../rivet/backend.rkt")
(define backend-namespace
  (module->namespace (module-path-index-resolve backend-module)))

(define (backend-private name)
  (parameterize ([current-namespace backend-namespace])
    (eval name)))

(define state-update-lock
  (backend-private 'state-update-lock))
(define state-update-locks-lock
  (backend-private 'state-update-locks-lock))

(define state
  (state-info 'state-order-lock-init 'Int64 (box 0) (make-semaphore 1)))
(define worker-count 32)
(define ready (make-channel))
(define results (make-async-channel))

;; Holding the registry lock before any worker starts guarantees that every
;; worker reaches the same first-access boundary before lookup/creation runs.
(semaphore-wait state-update-locks-lock)
(define workers
  (for/list ([i (in-range worker-count)])
    (thread
     (lambda ()
       (channel-put ready #t)
       (async-channel-put results (state-update-lock state))))))

(for ([i (in-range worker-count)])
  (channel-get ready))

;; A lookup that bypasses the registry lock would complete while it is held.
(check-false (sync/timeout 0.1 results))
(semaphore-post state-update-locks-lock)

(define locks
  (for/list ([i (in-range worker-count)])
    (define lock (sync/timeout 2 results))
    (check-not-false lock)
    lock))

(check-true
 (for/and ([lock (in-list (cdr locks))])
   (eq? lock (car locks))))

(for-each thread-wait workers)
