#lang racket/base

(require racket/file
         racket/list
         racket/path
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
   racketcs-def
   racket-framework)
  #:transparent)

(define boot-file-names
  '("petite.boot" "scheme.boot" "racket.boot"))

(define (existing-directory p)
  (and p (directory-exists? p) (simplify-path p #t)))

(define (existing-file p)
  (and p (file-exists? p) (simplify-path p #t)))

(define (unique-directories dirs)
  (remove-duplicates
   (filter values
           (for/list ([dir (in-list dirs)])
             (existing-directory dir)))
   equal?))

(define (boot-files-in dir)
  (and dir
       (let ([files
              (for/list ([name (in-list boot-file-names)])
                (existing-file (build-path dir name)))])
         (and (andmap values files) files))))

(define (find-complete-boot-files dirs)
  (for/or ([dir (in-list (unique-directories dirs))])
    (boot-files-in dir)))

(define (safe-directory-list dir)
  (with-handlers ([exn:fail:filesystem? (lambda (_) '())])
    (directory-list dir #:build? #t)))

(define (direct-matching-files dirs rx)
  (sort
   (remove-duplicates
    (for*/list ([dir (in-list (unique-directories dirs))]
                [path (in-list (safe-directory-list dir))]
                #:when (and (file-exists? path)
                            (regexp-match? rx
                                           (path->string
                                            (file-name-from-path path)))))
      (simplify-path path #t))
    equal?)
   string<?
   #:key path->string))

(define (find-direct-matching-file dirs rx)
  (define matches (direct-matching-files dirs rx))
  (and (pair? matches) (car matches)))

(define (framework-boot-directories framework)
  (define versions-dir
    (and framework
         (existing-directory (build-path framework "Versions"))))
  (if versions-dir
      (unique-directories
       (append
        (list (build-path versions-dir "Current" "boot"))
        (for/list ([entry (in-list (safe-directory-list versions-dir))]
                   #:when (directory-exists? entry))
          (build-path entry "boot"))))
      '()))

(define (direct-boot-directories lib-dir dll-dir)
  (unique-directories
   (list lib-dir
         dll-dir
         (and lib-dir (build-path lib-dir "boot"))
         (and dll-dir (build-path dll-dir "boot")))))

(define (required who label value)
  (or value
      (raise-arguments-error who
                             "could not locate a required file from the installed Racket CS runtime"
                             "missing" label
                             "Racket version" (version))))

(define (discover-racket-runtime)
  (define include-dir
    (required 'discover-racket-runtime "include directory"
              (existing-directory (find-include-dir))))
  (define lib-dir
    (required 'discover-racket-runtime "lib directory"
              (existing-directory (find-lib-dir))))
  (define dll-dir (existing-directory (find-dll-dir)))

  (define macos? (eq? (system-type 'os) 'macosx))
  (define framework-candidate (build-path lib-dir "Racket.framework"))
  (define racket-framework
    (and macos?
         (required 'discover-racket-runtime "Racket.framework"
                   (existing-directory framework-candidate))))

  ;; Runtime artifacts live in well-defined Racket installation directories.
  ;; Do not recursively search installation prefixes: on Unix that can turn a
  ;; simple `doctor` invocation into repeated scans of /usr.
  (define boot-dirs
    (append (if racket-framework
                (framework-boot-directories racket-framework)
                '())
            (direct-boot-directories lib-dir dll-dir)))
  (define boot-files
    (required 'discover-racket-runtime "petite.boot, scheme.boot, and racket.boot"
              (find-complete-boot-files boot-dirs)))
  (define petite (list-ref boot-files 0))
  (define scheme (list-ref boot-files 1))
  (define racket (list-ref boot-files 2))

  (define windows? (eq? (system-type 'os) 'windows))
  (define runtime-file-dirs (unique-directories (list dll-dir lib-dir)))
  (define racketcs-dll
    (and windows?
         (required 'discover-racket-runtime "libracketcs*.dll"
                   (find-direct-matching-file
                    runtime-file-dirs
                    #px"(?i:^libracketcs.*\\.dll$)"))))
  (define racketcs-def
    (and windows?
         (required 'discover-racket-runtime "libracketcs*.def"
                   (find-direct-matching-file
                    runtime-file-dirs
                    #px"(?i:^libracketcs.*\\.def$)"))))

  (racket-runtime (version)
                  include-dir
                  lib-dir
                  dll-dir
                  petite
                  scheme
                  racket
                  racketcs-dll
                  racketcs-def
                  racket-framework))

(module+ test-support
  (provide boot-files-in
           find-complete-boot-files
           direct-matching-files
           find-direct-matching-file
           framework-boot-directories
           direct-boot-directories))
