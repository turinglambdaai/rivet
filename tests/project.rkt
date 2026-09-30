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
             'resources '("assets" "locales/en.json")
             'windows-icon "branding/app.ico"
             'macos-icon "branding/app.icns"
             'macos-min-version "14.1"
             'windows-min-version "10.0.19045.0"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (define project (load-project temp-root))
    (check-equal? (project-name project) "demo")
    (check-equal? (project-display-name project) "Demo App")
    (check-equal? (project-version project) "1.2.3")
    (check-equal? (project-build project) 7)
    (check-equal? (project-identifier project) "dev.example.demo")
    (check-equal? (project-resources project) '("assets" "locales/en.json"))
    (check-equal? (project-windows-icon project) "branding/app.ico")
    (check-equal? (project-macos-icon project) "branding/app.icns")
    (check-equal? (project-macos-min-version project) "14.1")
    (check-equal? (project-windows-min-version project) "10.0.19045.0")
    (check-equal? (find-project temp-root) project)

    ;; 0.1 projects without release/platform metadata remain valid. All
    ;; consumers resolve the same compatibility defaults through project.rkt.
    (write-config
     (hasheq 'name "Demo_App"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (define legacy-project (load-project temp-root))
    (check-equal? (project-name legacy-project) "Demo_App")
    (check-equal? (project-display-name legacy-project) "Demo_App")
    (check-equal? (project-version legacy-project) default-project-version)
    (check-equal? (project-build legacy-project) default-project-build)
    (check-equal? (project-identifier legacy-project)
                  (default-project-identifier "Demo_App"))
    (check-equal? (project-identifier legacy-project) "dev.rivet.demo-app")
    (check-equal? (project-macos-min-version legacy-project)
                  default-macos-min-version)
    (check-equal? (project-windows-min-version legacy-project)
                  default-windows-min-version)
    (check-equal? (project-resources legacy-project) '())
    (check-false (project-windows-icon legacy-project))
    (check-false (project-macos-icon legacy-project))

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
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (write-config
     (hasheq 'name "demo"
             'macos-min-version "14"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (write-config
     (hasheq 'name "demo"
             'windows-min-version "10.0.19041"
             'backend "app/backend.rkt"
             'module "backend"
             'entry "start"
             'protocol 1))
    (check-exn exn:fail? (lambda () (load-project temp-root)))

    (for ([bad-resources (in-list '(("../secret")
                                    ("assets/../secret")
                                    (".")
                                    (".git/private")
                                    ("dist/generated")
                                    ("assets" "ASSETS")))])
      (write-config
       (hasheq 'name "demo"
               'resources bad-resources
               'backend "app/backend.rkt"
               'module "backend"
               'entry "start"
               'protocol 1))
      (check-exn exn:fail? (lambda () (load-project temp-root))))

    (for ([icon-config (in-list
                        (list (cons 'windows-icon "branding/app.png")
                              (cons 'windows-icon "../app.ico")
                              (cons 'macos-icon "branding/app.png")
                              (cons 'macos-icon ".rivet/app.icns")))])
      (write-config
       (hasheq 'name "demo"
               (car icon-config) (cdr icon-config)
               'backend "app/backend.rkt"
               'module "backend"
               'entry "start"
               'protocol 1))
      (check-exn exn:fail? (lambda () (load-project temp-root)))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
