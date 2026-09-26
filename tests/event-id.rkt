#lang racket/base

(require rackunit
         "../rivet/private/event-id.rkt")

(define max-event-id (sub1 (expt 2 64)))

(check-equal? first-event-id 1)
(check-equal? (advance-event-id 1) 2)
(check-equal? (advance-event-id (sub1 max-event-id)) max-event-id)
(check-equal? (advance-event-id max-event-id) first-event-id)

;; Event id 0 is reserved for connection-level frames, and values outside the
;; UInt64 wire domain must never enter the allocator state.
(for ([invalid (in-list (list 0 -1 (add1 max-event-id) 1.5 "1"))])
  (check-exn exn:fail:contract?
             (lambda () (advance-event-id invalid))))
