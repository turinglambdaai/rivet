#lang racket/base

(require racket/file
         racket/list
         racket/path)

(provide current-resource-root
         resource-root
         resource-path)

;; Tests, command-line tools, and specialized hosts may override discovery.
;; Normal native applications use the layout produced by `raco rivet build`
;; and `raco rivet package`.
(define current-resource-root
  (make-parameter
   #f
   (lambda (value)
     (unless (or (not value) (path-string? value))
       (raise-argument-error 'current-resource-root "(or/c #f path-string?)" value))
     (and value (simplify-path (path->complete-path value) #t)))))

(define (environment-resource-root)
  (define value (getenv "RIVET_RESOURCE_ROOT"))
  (and value
       (positive? (string-length value))
       (simplify-path (path->complete-path value) #t)))

(define (executable-resource-roots)
  (define executable
    (simplify-path (path->complete-path (find-system-path 'exec-file)) #t))
  (define executable-directory (path-only executable))
  (remove-duplicates
   (list
    ;; Windows packages and both platform development stages.
    (simplify-path (build-path executable-directory "app") #t)
    ;; macOS .app bundles: Contents/MacOS/<executable> -> Contents/Resources/app.
    (simplify-path
     (build-path executable-directory 'up "Resources" "app")
     #t))
   equal?))

(define (resource-root)
  (define configured (or (current-resource-root) (environment-resource-root)))
  (cond
    [configured
     (unless (directory-exists? configured)
       (raise-arguments-error 'resource-root
                              "configured Rivet application resource directory does not exist"
                              "directory" configured))
     configured]
    [else
     (or (for/first ([candidate (in-list (executable-resource-roots))]
                     #:when (directory-exists? candidate))
           candidate)
         (raise-arguments-error
          'resource-root
          "Rivet application resource directory was not found; configure resources in rivet.rktd or set current-resource-root for a custom host"
          "searched" (executable-resource-roots)))]))

(define (safe-resource-piece? value)
  (and (path-string? value)
       (let ([path (if (path? value) value (string->path value))])
         (and (relative-path? path)
              (andmap path? (explode-path path))))))

(define (resource-path . pieces)
  (for ([piece (in-list pieces)])
    (unless (safe-resource-piece? piece)
      (raise-arguments-error 'resource-path
                             "resource path components must be relative and must not contain '.' or '..'"
                             "component" piece)))
  (apply build-path (resource-root) pieces))
