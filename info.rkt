#lang info

(define collection 'multi)
(define version "0.2.0")
(define pkg-desc "Native desktop application foundation for Racket")
(define pkg-authors '(turinglambdaai))
(define license '(MIT))

(define deps
  '("base"
    "cext-lib"))

(define build-deps
  '("rackunit-lib"))

(define raco-commands
  '(("rivet" rivet-cli/main "create, build, and run Rivet applications" #f)))
