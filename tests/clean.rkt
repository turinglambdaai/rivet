#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../rivet-cli/clean.rkt"
         "../rivet-cli/project.rkt")

(define root (make-temporary-file "rivet-clean-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project (rivet-project root #hasheq()))
    (define source (build-path root "app" "backend.rkt"))
    (make-parent-directory* source)
    (call-with-output-file source
      #:exists 'truncate/replace
      (lambda (out) (display "#lang racket/base\n" out)))

    (for ([name (in-list '(".rivet" "build" "dist"))])
      (define generated (build-path root name))
      (make-directory* generated)
      (call-with-output-file (build-path generated "marker")
        #:exists 'truncate/replace
        (lambda (out) (display "generated" out))))

    (define removed (clean-project! project))
    (check-equal? (length removed) 3)
    (for ([name (in-list '(".rivet" "build" "dist"))])
      (check-false (file-or-directory-type (build-path root name) #f)))
    (check-true (file-exists? source))

    ;; Clean is idempotent when no generated artifacts exist.
    (check-equal? (clean-project! project) '()))
  (lambda ()
    (when (directory-exists? root)
      (delete-directory/files root))))
