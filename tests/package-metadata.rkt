#lang racket/base

(require rackunit
         racket/runtime-path)

(define-runtime-path info-path "../info.rkt")

(define info-module
  (parameterize ([read-accept-reader #t])
    (call-with-input-file info-path read)))

(define (find-definition datum name)
  (cond
    [(and (list? datum)
          (= (length datum) 3)
          (eq? (car datum) 'define)
          (eq? (cadr datum) name))
     (caddr datum)]
    [(list? datum)
     (for/or ([child (in-list datum)])
       (find-definition child name))]
    [else #f]))

(define deps-expression (find-definition info-module 'deps))
(check-not-false deps-expression "info.rkt must define deps")

(define dependencies
  (if (and (pair? deps-expression)
           (eq? (car deps-expression) 'quote))
      (cadr deps-expression)
      '()))

(define dependency-names
  (for/list ([dependency (in-list dependencies)])
    (if (string? dependency) dependency (car dependency))))

;; Rivet needs the modules from crypto-lib, not the crypto meta package. The
;; latter also pulls documentation-only packages into end-user installations.
(check-not-false (member "crypto-lib" dependency-names)
                 "runtime crypto modules must remain declared")
(check-false (member "crypto" dependency-names)
             "do not reintroduce the crypto documentation meta package")
