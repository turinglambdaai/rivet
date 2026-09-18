#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../rivet-cli/project.rkt")

(define temp-root (make-temporary-file "rivet-project-~a" 'directory))

(define (write-config value)
  (call-with-output-file (build-path temp-root "rivet.rktd")
    #:exists 'truncate/replace
    (lambda (out) (write value out))))

(dynamic-wind
  void
  (lambda ()
    (write-config
     (hasheq 'name "demo"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (define project (load-project temp-root))
    (check-equal? (project-ref project 'name) "demo")
    (check-equal? (find-project temp-root) project)

    (write-config
     (hasheq 'name "demo"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 99))
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (write-config
     (hasheq 'name "demo"
             'backend (path->string (build-path temp-root "backend.rkt"))
             'module "backend"
             'entry "start"
             'protocol 1))
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (write-config
     (hasheq 'name "demo"
             'backend "app/backend.rkt"
             'module "backend"
             'protocol 1))
    (check-exn exn:fail? (lambda () (load-project temp-root))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
