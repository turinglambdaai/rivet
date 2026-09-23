#lang racket/base

(require rackunit
         "../rivet/protocol.rkt")

(define custom-write-count 0)

(struct explosive-value ()
  #:property prop:custom-write
  (lambda (_value _out _mode)
    (set! custom-write-count (add1 custom-write-count))
    (error 'explosive-value "custom writer must not run")))

(define (check-safe-unsupported value)
  (check-exn #rx"value is not supported by protocol v1"
             (lambda () (encode-value value)))
  (check-equal? custom-write-count 0))

;; Both a root unsupported object and one discovered inside an otherwise legal
;; List must fail without asking the application object to render itself.
(check-safe-unsupported (explosive-value))
(check-safe-unsupported (list "prefix" (explosive-value)))
