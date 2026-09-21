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
             'display-name "Demo App"
             'version "1.2.3"
             'build 7
             'identifier "dev.example.demo"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (define project (load-project temp-root))
    (check-equal? (project-ref project 'name) "demo")
    (check-equal? (project-ref project 'display-name) "Demo App")
    (check-equal? (project-ref project 'version) "1.2.3")
    (check-equal? (project-ref project 'build) 7)
    (check-equal? (project-ref project 'identifier) "dev.example.demo")
    (check-equal? (find-project temp-root) project)

    ;; 0.1 projects without release metadata remain valid.
    (write-config
     (hasheq 'name "demo"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (check-not-exn (lambda () (load-project temp-root)))

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
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (write-config
     (hasheq 'name "demo"
             'version "1.0.0"
             'build 0
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (write-config
     (hasheq 'name "demo"
             'identifier "bad identifier"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (check-exn exn:fail? (lambda () (load-project temp-root))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
