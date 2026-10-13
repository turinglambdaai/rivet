#lang racket/base

(require file/zip
         rackunit
         racket/file
         racket/path
         "../rivet-cli/project.rkt"
         "../rivet-cli/release-layout.rkt"
         (submod "../rivet-cli/verify.rkt" test-support))

(define temp-root
  (make-temporary-file "rivet-verify-release-archive-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project
      (rivet-project temp-root
                     #hasheq((name . "Example")
                             (version . "2.3.4"))))
    (define package
      (case (system-type 'os)
        [(windows)
         (build-path temp-root "dist" "Example-windows-x64")]
        [(macosx)
         (build-path temp-root "dist" "Example.app")]
        [(unix)
         (build-path temp-root "dist" "Example-linux-x64")]))
    (define staged-package (build-path temp-root (file-name-from-path package)))
    (make-directory* staged-package)
    (call-with-output-file (build-path staged-package "payload.txt")
      (lambda (out) (display "released payload" out)))
    (make-directory* (build-path temp-root "dist"))
    (define archive (portable-zip-path project))
    (parameterize ([current-directory temp-root])
      (zip archive (path->string (file-name-from-path staged-package))))
    (delete-directory/files staged-package)

    (define extracted-root #f)
    (define verified
      (call-with-project-package-for-verification
       project package
       (lambda (extracted)
         (set! extracted-root extracted)
         (check-equal?
          (file->string (build-path extracted "payload.txt"))
          "released payload"))))
    (check-equal? verified archive)
    (check-false (directory-exists? extracted-root))

    (define wrong-root (build-path temp-root "Wrong-linux-x64"))
    (make-directory wrong-root)
    (delete-file archive)
    (parameterize ([current-directory temp-root])
      (zip archive (path->string (file-name-from-path wrong-root))))
    (check-exn #rx"archive root does not match"
               (lambda ()
                 (call-with-project-package-for-verification
                  project package void))))
  (lambda ()
    (delete-directory/files temp-root #:must-exist? #f)))
