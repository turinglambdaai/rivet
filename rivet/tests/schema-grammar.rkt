#lang racket/base

(require rackunit
         rivet)

;; The capitalized identifiers are intentionally unbound outside these forms.
;; Successful expansion proves that they are declaration grammar rather than
;; runtime descriptor values exported by `rivet`.
(define-rpc (echo [value : String] : String)
  value)

(define-state ready? : Bool #f)

(check-equal? (echo "hello") "hello")
(check-false (state-ref ready?))
