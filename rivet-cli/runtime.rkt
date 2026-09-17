#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         setup/dirs)

(provide (struct-out racket-runtime)
         discover-racket-runtime)

(struct racket-runtime
  (version
   include-dir
   lib-dir
   dll-dir
   petite-boot
   scheme-boot
   racket-boot
   racketcs-dll
   racketcs-def)
  #:transparent)

(define (existing-directory p)
  (and p (directory-exists? p) (simplify-path p #t)))

(define (candidate-roots)
  (define exe (find-executable-path "racket"))
  (define dirs
    (filter values
            (list (existing-directory (find-lib-dir))
                  (existing-directory (find-dll-dir))
                  (existing-directory (find-include-dir))
                  (and exe (existing-directory (path-only exe))))))
  (remove-duplicates
   (append dirs
           (for/list ([dir (in-list dirs)])
             (existing-directory (build-path dir 'up))))
   equal?))

(define (safe-find-files predicate root)
  (with-handlers ([exn:fail:filesystem? (lambda (_) '())])
    (find-files predicate root)))

(define (file-name-string p)
  (path->string (file-name-from-path p)))

(define (find-by-name name roots)
  (for*/first ([root (in-list roots)]
               [path (in-list
                      (safe-find-files
                       (lambda (p)
                         (and (file-exists? p)
                              (string-ci=? (file-name-string p) name)))
                       root))])
    (simplify-path path #t)))

(define (find-by-regexp rx roots)
  (for*/first ([root (in-list roots)]
               [path (in-list
                      (safe-find-files
                       (lambda (p)
                         (and (file-exists? p)
                              (regexp-match? rx (file-name-string p))))
                       root))])
    (simplify-path path #t)))

(define (required who label value)
  (or value
      (raise-arguments-error who
                             "could not locate a required file from the installed Racket CS runtime"
                             "missing" label
                             "Racket version" (version))))

(define (discover-racket-runtime)
  (define roots (candidate-roots))
  (define include-dir
    (required 'discover-racket-runtime "include directory"
              (existing-directory (find-include-dir))))
  (define lib-dir
    (required 'discover-racket-runtime "lib directory"
              (existing-directory (find-lib-dir))))
  (define dll-dir (existing-directory (find-dll-dir)))

  (define petite
    (required 'discover-racket-runtime "petite.boot"
              (find-by-name "petite.boot" roots)))
  (define scheme
    (required 'discover-racket-runtime "scheme.boot"
              (find-by-name "scheme.boot" roots)))
  (define racket
    (required 'discover-racket-runtime "racket.boot"
              (find-by-name "racket.boot" roots)))

  (define windows? (eq? (system-type 'os) 'windows))
  (define racketcs-dll
    (and windows?
         (required 'discover-racket-runtime "libracketcs*.dll"
                   (find-by-regexp #px"(?i:^libracketcs.*\\.dll$)" roots))))
  (define racketcs-def
    (and windows?
         (required 'discover-racket-runtime "libracketcs*.def"
                   (find-by-regexp #px"(?i:^libracketcs.*\\.def$)" roots))))

  (racket-runtime (version)
                  include-dir
                  lib-dir
                  dll-dir
                  petite
                  scheme
                  racket
                  racketcs-dll
                  racketcs-def))
