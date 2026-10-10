#lang racket/base

(provide make-pending-table
         (struct-out pending-table)
         pending-request?
         pending-request-custodian)

;; Pending requests have one terminal owner. Completion, failure, and
;; cancellation race through this table, while a short state-commit barrier can
;; defer cancellation until the matching State event has entered the output
;; queue. Keeping this state machine separate makes its invariants directly
;; testable without exposing it from rivet/backend.
(struct pending-request
  (custodian terminal-owned cancel-deferred cancel-requested)
  #:mutable)

(struct pending-table
  (id-pending?
   admit!
   claim!
   cancel-action!
   begin-state-commit!
   end-state-commit!
   release!
   take-all!)
  #:transparent)

(define (make-pending-table limit)
  (unless (exact-positive-integer? limit)
    (raise-argument-error 'make-pending-table "exact-positive-integer?" limit))

  (define entries (make-hash))
  (define lock (make-semaphore 1))

  (define (id-pending? id)
    (call-with-semaphore
     lock
     (lambda () (hash-has-key? entries id))))

  (define (admit! id custodian)
    (call-with-semaphore
     lock
     (lambda ()
       (cond
         [(hash-has-key? entries id) 'duplicate]
         [(>= (hash-count entries) limit) 'full]
         [else
          (hash-set! entries id (pending-request custodian #f #f #f))
          'admitted]))))

  (define (claim! id)
    ;; Claim terminal ownership without freeing capacity. A completed request
    ;; continues to occupy its slot until its terminal frame is accepted by the
    ;; bounded output queue, so backpressure cannot be bypassed.
    (call-with-semaphore
     lock
     (lambda ()
       (define request (hash-ref entries id #f))
       (cond
         [(and request
               (not (pending-request-terminal-owned request)))
          (set-pending-request-terminal-owned! request #t)
          request]
         [else #f]))))

  (define (cancel-action! id)
    (call-with-semaphore
     lock
     (lambda ()
       (define request (hash-ref entries id #f))
       (cond
         [(or (not request)
              (pending-request-terminal-owned request))
          #f]
         [(pending-request-cancel-deferred request)
          (set-pending-request-cancel-requested! request #t)
          'deferred]
         [else
          (set-pending-request-terminal-owned! request #t)
          request]))))

  (define (begin-state-commit! id)
    (call-with-semaphore
     lock
     (lambda ()
       (define request (hash-ref entries id #f))
       (cond
         [(not request) 'untracked]
         [(pending-request-terminal-owned request) 'terminal]
         [else
          (set-pending-request-cancel-deferred! request #t)
          request]))))

  (define (end-state-commit! id request)
    ;; Clear the barrier and atomically convert a deferred Cancel into terminal
    ;; ownership before another Cancel or normal Response can race in.
    (call-with-semaphore
     lock
     (lambda ()
       (define current (hash-ref entries id #f))
       (cond
         [(not (eq? current request)) #f]
         [else
          (set-pending-request-cancel-deferred! request #f)
          (cond
            [(and (pending-request-cancel-requested request)
                  (not (pending-request-terminal-owned request)))
             (set-pending-request-terminal-owned! request #t)
             request]
            [else #f])]))))

  (define (release! id request)
    ;; Identity guards against an old worker releasing a newer request that
    ;; reused the same wire correlation id.
    (call-with-semaphore
     lock
     (lambda ()
       (when (eq? (hash-ref entries id #f) request)
         (hash-remove! entries id)))))

  (define (take-all!)
    (call-with-semaphore
     lock
     (lambda ()
       (define requests (hash-values entries))
       (hash-clear! entries)
       (map pending-request-custodian requests))))

  (pending-table id-pending?
                 admit!
                 claim!
                 cancel-action!
                 begin-state-commit!
                 end-state-commit!
                 release!
                 take-all!))
