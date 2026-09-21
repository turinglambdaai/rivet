#lang racket/base

(require racket/file
         racket/path
         rackunit
         (submod "../rivet-cli/windows-tools.rkt" test-support))

(define temp-root (make-temporary-file "rivet-windows-tools-~a" 'directory))

(define (touch path)
  (make-directory* (path-only path))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display "fixture" out)))
  (simplify-path path #t))

(define (write-vc-toolset root version #:complete? [complete? #t])
  (define bin-dir
    (build-path root "VC" "Tools" "MSVC" version "bin" "Hostx64" "x64"))
  (define cl (touch (build-path bin-dir "cl.exe")))
  (if complete?
      (list cl
            (touch (build-path bin-dir "lib.exe"))
            (touch (build-path bin-dir "dumpbin.exe")))
      (list cl)))

(dynamic-wind
  void
  (lambda ()
    ;; The newest complete MSVC directory wins. A newer partial directory must
    ;; not be combined with tools from another toolset.
    (write-vc-toolset temp-root "14.50.00000" #:complete? #f)
    (define expected-vc (write-vc-toolset temp-root "14.49.99999"))
    (check-equal? (vc-toolset-in-installation temp-root) expected-vc)

    ;; Files hidden under an unexpected nested layout are deliberately ignored.
    (define unexpected
      (build-path temp-root "VC" "Tools" "MSVC" "14.60.00000" "nested"))
    (touch (build-path unexpected "cl.exe"))
    (touch (build-path unexpected "lib.exe"))
    (touch (build-path unexpected "dumpbin.exe"))
    (check-equal? (vc-toolset-in-installation temp-root) expected-vc)

    ;; Prefer Visual Studio's stable Current alias for MSBuild.
    (define current-msbuild
      (touch (build-path temp-root "MSBuild" "Current" "Bin" "MSBuild.exe")))
    (touch (build-path temp-root "MSBuild" "18.0" "Bin" "MSBuild.exe"))
    (check-equal? (msbuild-in-installation temp-root) current-msbuild)

    ;; Without Current, choose the newest bounded MSBuild directory.
    (define fallback-root (build-path temp-root "fallback"))
    (touch (build-path fallback-root "MSBuild" "17.0" "Bin" "MSBuild.exe"))
    (define newest-msbuild
      (touch (build-path fallback-root "MSBuild" "18.0" "Bin" "MSBuild.exe")))
    (check-equal? (msbuild-in-installation fallback-root) newest-msbuild)

    (define children
      (sorted-child-directories (build-path fallback-root "MSBuild")))
    (check-equal? (map file-name-from-path children)
                  (map string->path '("18.0" "17.0"))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
