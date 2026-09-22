#lang racket/base

(require racket/file
         racket/path
         racket/runtime-path
         "project.rkt")

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

(define-event notification : String)
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (notify [message String] : Void)
  (notification message)
  (void))

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
   (format
    "#hasheq((name . ~s) (display-name . ~s) (version . ~s) (build . ~s) (identifier . ~s) (macos-min-version . ~s) (windows-min-version . ~s) (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1))\n"
    name
    name
    default-project-version
    default-project-build
    (default-project-identifier name)
    default-macos-min-version
    default-windows-min-version))
  (write-text (build-path root "app" "backend.rkt") backend-template)
  (write-text (build-path root ".gitignore") ".rivet/\nbuild/\ndist/\n.DS_Store\n")

  (define windows-template
    (build-path (simplify-path rivet-root #t) "platform" "windows" "host"))
  (unless (directory-exists? windows-template)
    (error 'rivet-new "Windows host template is missing: ~a" windows-template))
  (copy-directory/files windows-template (build-path root "windows"))

  (define macos-template
    (build-path (simplify-path rivet-root #t) "platform" "macos" "host"))
  (unless (directory-exists? macos-template)
    (error 'rivet-new "macOS host template is missing: ~a" macos-template))
  ;; Keep the app host directory distinct from Rivet's own platform/macos
  ;; package. SwiftPM uses the final path element as local package identity.
  (copy-directory/files macos-template (build-path root "macos-host"))
  root)
