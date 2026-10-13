#lang racket/base

;; Regression guard for #235. The native compilers are platform-specific and
;; run in CI, while this cross-platform test keeps the package boundary from
;; silently returning to incremental build caches.

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "..")

(define build-source
  (file->string (build-path repository-root "rivet-cli" "build.rkt")))
(define package-source
  (file->string (build-path repository-root "rivet-cli" "package.rkt")))

(check-true (string-contains? package-source "#:clean-native? #t")
            "package must request a clean native build")
(check-true (string-contains? build-source "\"/t:Rebuild\"")
            "Windows package builds must use MSBuild Rebuild")
(check-true (regexp-match? #px"clean-native[?][^)]*fresh-directory! build-dir"
                           build-source)
            "macOS package builds must recreate the Swift scratch tree")
