#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/runtime-path)

(provide create-project!)

(define-runtime-path rivet-root "..")

(define (safe-project-name? s)
  (regexp-match? #px"^[A-Za-z][A-Za-z0-9_-]*$" s))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'error
    (lambda (out) (display text out))))

(define backend-template
  #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
  )

(define (create-project! name [parent (current-directory)])
  (unless (safe-project-name? name)
    (raise-arguments-error 'rivet-new
                           "invalid project name; use letters, digits, '-' or '_'"
                           "name" name))
  (define root (build-path parent name))
  (when (or (directory-exists? root) (file-exists? root))
    (raise-arguments-error 'rivet-new "destination already exists" "path" root))

  (make-directory* root)
  (write-text
   (build-path root "README.md")
   (format "# ~a\n\nA native desktop app powered by Racket and Rivet.\n\n```bash\nraco rivet doctor\nraco rivet dev\n```\n" name))
  (write-text
   (build-path root "rivet.rktd")
   (format "#hasheq((name . ~s) (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1))\n" name))
  (write-text (build-path root "app" "backend.rkt") backend-template)
  (write-text (build-path root ".gitignore") ".rivet/\nbuild/\ndist/\n.DS_Store\n")

  (define windows-template
    (build-path (simplify-path rivet-root #t) "platform" "windows" "host"))
  (unless (directory-exists? windows-template)
    (error 'rivet-new "Windows host template is missing: ~a" windows-template))
  (copy-directory/files windows-template (build-path root "windows"))
  (make-directory* (build-path root "macos"))
  root)
