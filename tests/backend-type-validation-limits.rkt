#lang racket/base

(require rackunit
         racket/list
         (for-syntax racket/base
                     "../rivet/protocol.rkt")
         "../rivet/backend.rkt"
         "../rivet/protocol.rkt")

(define-event bounded-int-list-event : (List Int64))

;; The outer List itself consumes one RVT1 value node. Exactly
;; max-value-nodes - 1 scalar children therefore fits the protocol budget. With
;; no server active, reaching emit-event! proves type validation accepted it.
(let ([value (make-list (sub1 max-value-nodes) 1)])
  (check-exn #rx"no Rivet server is active"
             (lambda () (bounded-int-list-event value))))

;; One additional child exceeds the total value-node budget. Typed validation
;; must reject this before it can reach emit-event! or perform an unbounded
;; full-List traversal ahead of the protocol encoder.
(let ([value (make-list max-value-nodes 1)])
  (check-exn #rx"value node count exceeds Rivet protocol limit"
             (lambda () (bounded-int-list-event value))))

;; Build a declaration with one List layer beyond the RVT1 nesting limit
;; without hand-writing dozens of nested forms.
(define-syntax (define-too-deep-event stx)
  (define type-stx
    (for/fold ([type-stx #'Int64])
              ([i (in-range (add1 max-value-depth))])
      #`(List #,type-stx)))
  #`(define-event too-deep-event : #,type-stx))

(define-too-deep-event)

(define too-deep-value
  (for/fold ([value 1])
            ([i (in-range (add1 max-value-depth))])
    (list value)))

(check-exn #rx"value nesting exceeds Rivet protocol limit"
           (lambda () (too-deep-event too-deep-value)))

;; Improper pair-shaped values remain ordinary type mismatches; diagnostics do
;; not need to prove proper-List-ness by traversing arbitrary tails.
(check-exn #rx"value does not match declared Rivet type"
           (lambda () (bounded-int-list-event (cons 1 2))))
