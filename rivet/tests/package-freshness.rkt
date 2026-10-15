#lang racket/base

;; Regression guard for #235. The native compilers are platform-specific and
;; run in CI, while this cross-platform test keeps the package boundary from
;; silently returning to incremental build caches.

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         (submod "../../rivet-cli/package.rkt" test-support))

(define-runtime-path repository-root "../..")

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

;; A retry over a dirty Windows package target must replace the old tree. This
;; is the copy path whose previous create-only behavior raised "destination
;; exists" after a failed or repeated release.
(define temp-root (make-temporary-file "rivet-package-retry-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define stage (build-path temp-root "stage"))
    (define destination (build-path temp-root "dist" "Example-windows-x64"))
    (make-directory* (build-path stage "res"))
    (call-with-output-file (build-path stage "RivetHost.exe")
      #:exists 'truncate/replace
      (lambda (out) (display "first" out)))
    (call-with-output-file (build-path stage "res" "current.txt")
      #:exists 'truncate/replace
      (lambda (out) (display "current" out)))
    (copy-windows-release! stage destination)

    (call-with-output-file (build-path destination "stale.txt")
      #:exists 'truncate/replace
      (lambda (out) (display "stale" out)))
    (call-with-output-file (build-path stage "RivetHost.exe")
      #:exists 'truncate/replace
      (lambda (out) (display "second" out)))
    (copy-windows-release! stage destination)

    (check-equal? (file->string (build-path destination "RivetHost.exe"))
                  "second")
    (check-true (file-exists? (build-path destination "res" "current.txt")))
    (check-false (file-exists? (build-path destination "stale.txt"))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
