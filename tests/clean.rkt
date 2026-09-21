#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../rivet-cli/clean.rkt"
         "../rivet-cli/project.rkt")

(define root (make-temporary-file "rivet-clean-~a" 'directory))
(define external (make-temporary-file "rivet-clean-external-~a" 'directory))

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
    (check-equal? (clean-project! project) '())

    ;; A generated path may be redirected through a symlink/junction. Clean
    ;; must remove the link itself and never recurse into an external target.
    (define external-marker (build-path external "keep-me"))
    (call-with-output-file external-marker
      #:exists 'truncate/replace
      (lambda (out) (display "external" out)))
    (define linked-build (build-path root "build"))
    (make-file-or-directory-link external linked-build)
    (check-true (link-exists? linked-build))
    (check-equal? (clean-project! project) (list linked-build))
    (check-false (link-exists? linked-build))
    (check-true (file-exists? external-marker))
    (check-true (file-exists? source)))
  (lambda ()
    (when (directory-exists? root)
      (delete-directory/files root))
    (when (directory-exists? external)
      (delete-directory/files external))))
