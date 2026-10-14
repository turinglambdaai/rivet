#lang racket/base

(require rackunit
         racket/file
         (submod "../../rivet-cli/build.rkt" test-support)
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-build-schema-gate-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "schema-gate" temp-root))
    (define project (load-project project-root))
    (define compatible-report (check-project-schema-baseline! project))
    (check-true (hash-ref compatible-report 'compatible))

    (call-with-output-file
     (build-path project-root "app" "backend.rkt")
     #:exists 'truncate/replace
     (lambda (out)
       (display
        #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
        out)))
    (check-exn #rx"incompatible with rivet-schema.json.*notification was removed"
               (lambda () (check-project-schema-baseline! project)))

    (delete-file (build-path project-root "rivet-schema.json"))
    (check-false (check-project-schema-baseline! project)))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
