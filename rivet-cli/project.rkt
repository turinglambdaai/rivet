#lang racket/base

(require racket/file
         racket/path)

(provide (struct-out rivet-project)
         find-project
         load-project
         project-ref
         project-path)

(struct rivet-project (root config) #:transparent)

(define config-name "rivet.rktd")

(define (load-config path)
  (define value
    (call-with-input-file path
      (lambda (in) (read in))))
  (unless (hash? value)
    (raise-arguments-error 'load-project
                           "rivet.rktd must contain a hash"
                           "path" path
                           "value" value))
  value)

(define (load-project root)
  (define complete (simplify-path (path->complete-path root) #t))
  (define config-path (build-path complete config-name))
  (unless (file-exists? config-path)
    (raise-arguments-error 'load-project
                           "not a Rivet project (rivet.rktd is missing)"
                           "directory" complete))
  (rivet-project complete (load-config config-path)))

(define (find-project [start (current-directory)])
  (let loop ([dir (simplify-path (path->complete-path start) #t)])
    (define config-path (build-path dir config-name))
    (cond
      [(file-exists? config-path) (load-project dir)]
      [else
       (define parent (simplify-path (build-path dir 'up) #t))
       (and (not (equal? parent dir))
            (loop parent))])))

(define (project-ref project key [failure-thunk #f])
  (hash-ref (rivet-project-config project)
            key
            (or failure-thunk
                (lambda ()
                  (raise-arguments-error
                   'project-ref
                   "missing required Rivet project setting"
                   "key" key
                   "project" (rivet-project-root project))))))

(define (project-path project . pieces)
  (apply build-path (rivet-project-root project) pieces))
