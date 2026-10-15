#lang racket/base

(require rackunit
         racket/file
         (submod "../../rivet-cli/build.rkt" test-support))

(define temp-root (make-temporary-file "rivet-backend-build-~a" 'directory))
(define dependency-before
  "#lang racket/base\n(provide value)\n(define value 'before)\n")
(define dependency-after
  "#lang racket/base\n(provide value)\n(define value 'after!)\n")

(define (write-module path text)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display text out))))

;; The stale-cache regression is observed through the bundle bytes rather
;; than a per-module .zo path: hosts may redirect compiled output with
;; PLTCOMPILEDROOTS (the package build farm does), so only the explicit
;; bundle location is position-independent.
(dynamic-wind
  void
  (lambda ()
    (define backend (build-path temp-root "backend.rkt"))
    (define dependency (build-path temp-root "dependency.rkt"))
    (define bundle (build-path temp-root "core.zo"))

    (write-module backend
                  "#lang racket/base\n(require \"dependency.rkt\")\n(provide result)\n(define result value)\n")
    (check-equal? (string-length dependency-before)
                  (string-length dependency-after))
    (write-module dependency dependency-before)
    (compile-backend-module-bundle! backend bundle)
    (define before (file->bytes bundle))
    (check-true (file-exists? bundle))

    ;; Keep the source length unchanged while making it newer than the cached
    ;; bytecode, matching the regression reported by a real Rivet application.
    (write-module dependency dependency-after)
    (define source-time (file-or-directory-modify-seconds dependency))
    (define compiled-dependency
      (build-path temp-root "compiled" "dependency_rkt.zo"))
    (when (file-exists? compiled-dependency)
      (for ([compiled (in-list
                       (list compiled-dependency
                             (build-path temp-root "compiled"
                                         "dependency_rkt.dep")))])
        (file-or-directory-modify-seconds compiled (sub1 source-time))))
    (compile-backend-module-bundle! backend bundle)

    (check-not-equal? (file->bytes bundle) before))
  (lambda ()
    (delete-directory/files temp-root)))
