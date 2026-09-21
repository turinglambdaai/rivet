#lang racket/base

(require racket/file
         racket/path
         "project.rkt")

(provide clean-project!)

(define generated-directories '(".rivet" "build" "dist"))

(define (remove-generated-path! path)
  (define kind (file-or-directory-type path #f))
  (case kind
    [(link file)
     ;; A file/symbolic link is removed as a link; its destination is never
     ;; traversed by the cleaner.
     (delete-file path)
     #t]
    [(directory-link)
     ;; Racket reports Windows junctions/directory symlinks separately and
     ;; requires delete-directory for that link kind. This removes the link
     ;; itself instead of recursively deleting its target.
     (delete-directory path)
     #t]
    [(directory)
     (delete-directory/files path)
     #t]
    [else #f]))

(define (clean-project! project)
  (for/list ([name (in-list generated-directories)]
             #:do [(define path (project-path project name))]
             #:when (remove-generated-path! path))
    path))
