#lang info

(define collection 'multi)
(define version "0.0.1")
(define pkg-desc "Native desktop application foundation for Racket")
(define pkg-authors '(turinglambdaai))
(define license '(MIT))

(define deps
  '("base"
    "cext-lib"
    "rackunit-lib"))

(define build-deps
  '("scribble-lib"
    "racket-doc"))

(define raco-commands
  '(("rivet" rivet-cli/main "create, build, and run Rivet applications" #f)))
