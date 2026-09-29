#lang info

(define collection 'multi)
;; Racket package versions reject a trailing ".0" component. Release tags and
;; native artifacts remain three-component SemVer via `release-version`.
(define version "0.3")
(define release-version "0.3.0")
(define pkg-desc "Native desktop application foundation for Racket")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)

(define deps
  '("base"
    "cext-lib"
    "crypto-lib"
    "net-lib"))

(define build-deps
  '("racket-doc"
    "rackunit-lib"
    "scribble-lib"))

(define raco-commands
  '(("rivet" rivet-cli/main "create, build, and run Rivet applications" #f)))
