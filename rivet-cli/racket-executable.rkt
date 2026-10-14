#lang racket/base

;; Resolves the console executables of the running Racket installation.
;; Build hosts do not always put the installation's bin directory on PATH —
;; the package build farm invokes bin/racket by a relative path from the
;; installation root — so consult the setup-reported console bin directory
;; before falling back to PATH.

(require setup/dirs)

(provide resolve-racket-executable
         resolve-raco-executable)

(define (resolve-console-executable who name)
  (define bin-dir (find-console-bin-dir))
  (define candidate
    (and bin-dir
         (build-path bin-dir
                     (if (eq? (system-type 'os) 'windows)
                         (string-append name ".exe")
                         name))))
  (or (and candidate (file-exists? candidate) candidate)
      (find-executable-path name)
      (raise-arguments-error who
                             "console executable was not found"
                             "name" name
                             "console bin directory" bin-dir)))

(define (resolve-racket-executable)
  (resolve-console-executable 'resolve-racket-executable "racket"))

(define (resolve-raco-executable)
  (resolve-console-executable 'resolve-raco-executable "raco"))
