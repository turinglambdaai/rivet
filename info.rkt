#lang info

(define collection 'multi)
;; Racket package versions reject a trailing ".0" component. Release tags and
;; native artifacts remain three-component SemVer via `release-version`.
(define version "0.10")
(define release-version "0.10.0")
(define pkg-desc "Native application foundation for Racket")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)

(define deps
  '(["base" #:version "9.0"]
    "cext-lib"
    "crypto-lib"
    ["keel" #:version "0.3.1"]
    "net-lib"))

(define build-deps
  '("racket-doc"
    "rackunit-lib"
    "scribble-lib"))

;; `raco pkg create` does not consult .gitignore. Keep local native build and
;; application-output trees out of source releases even when maintainers run
;; the release smoke immediately after compiling every platform adapter.
(define source-omit-files
  '(".rivet"
    "build"
    "dist"
    "platform/macos/.build"))

(define raco-commands
  '(("rivet" rivet-cli/main "create, build, and run Rivet applications" #f)))
