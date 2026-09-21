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
     ;; Do not follow a project-local symlink/junction into an arbitrary
     ;; external directory. Removing the link itself is the safe clean action.
     (delete-file path)
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
