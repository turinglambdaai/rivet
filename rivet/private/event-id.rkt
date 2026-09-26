#lang racket/base

(provide first-event-id
         advance-event-id)

;; Event id 0 is reserved for connection-level frames such as Hello/Shutdown.
;; Keep application Events in the non-zero UInt64 domain used by RVT1 frames.
(define first-event-id 1)
(define max-event-id (sub1 (expt 2 64)))

(define (advance-event-id id)
  (unless (and (exact-integer? id)
               (<= first-event-id id max-event-id))
    (raise-argument-error
     'advance-event-id
     (format "exact integer in [~a, ~a]" first-event-id max-event-id)
     id))
  (if (= id max-event-id)
      first-event-id
      (add1 id)))
