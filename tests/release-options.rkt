#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/string
         "../rivet/distribution/manifest.rkt"
         "../rivet-cli/appimage.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/release.rkt"
         (submod "../rivet-cli/release.rkt" test-support))

(define update-variable-names
  '("RIVET_UPDATE_BASE_URL"
    "RIVET_UPDATE_PRIVATE_KEY"
    "RIVET_UPDATE_KEY_ID"))

(define (without-update-environment thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([name (in-list update-variable-names)])
    (environment-variables-set! env (string->bytes/utf-8 name) #f))
  (parameterize ([current-environment-variables env])
    (thunk)))

(without-update-environment
 (lambda ()
   (check-false (release-update-environment #f))
   (check-exn #rx"RIVET_UPDATE_BASE_URL"
              (lambda () (release-update-environment #t)))))

(define complete-env
  (environment-variables-copy (current-environment-variables)))
(environment-variables-set! complete-env
                            #"RIVET_UPDATE_BASE_URL"
                            #"https://downloads.example.test/app/")
(environment-variables-set! complete-env
                            #"RIVET_UPDATE_PRIVATE_KEY"
                            #"keys/update.der")
(environment-variables-set! complete-env
                            #"RIVET_UPDATE_KEY_ID"
                            #"release-2026")
(parameterize ([current-environment-variables complete-env])
  (check-not-false (release-update-environment #t)))

(define temp-root (make-temporary-file "rivet-release-options-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define project
      (rivet-project temp-root
                     #hasheq((name . "Example")
                             (version . "2.3.4"))))
    (define zip-name
      (path->string (file-name-from-path (portable-zip-path project))))
    (check-regexp-match
     #rx"^Example-2\\.3\\.4-(windows|macos|linux)-(x64|arm64)\\.zip$"
     zip-name)
    (define package (build-path temp-root "dist" "Example-package"))
    (make-directory* package)
    (call-with-output-file (build-path package "payload.txt")
      #:exists 'truncate/replace
      (lambda (out) (display "portable payload" out)))
    (define archive (create-portable-zip! project package))
    (check-equal? archive (portable-zip-path project))
    (check-true (file-exists? archive))
    (check-true
     (file-exists? (string-append (path->string archive) ".sha256")))
    (define artifact
      (parameterize ([current-environment-variables complete-env])
        (portable-update-artifact (release-update-environment #t) archive)))
    (check-equal? (update-artifact-installer artifact) 'zip)
    (check-equal? (update-artifact-size artifact) (file-size archive))
    (check-true
     (string-suffix? (update-artifact-url artifact) zip-name))

    ;; AppImage is selected by the signed manifest itself. Products never
    ;; derive a sibling URL or trust a detached sidecar instead of the feed.
    (define appimage-project
      (rivet-project temp-root
                     #hasheq((name . "Example")
                             (version . "2.3.4")
                             (linux-formats . ("appimage")))))
    (define appimage (appimage-installer-path appimage-project))
    (call-with-output-file appimage
      #:exists 'truncate/replace #:mode 'binary
      (lambda (out) (write-bytes #"appimage-payload" out)))
    (define appimage-artifact
      (parameterize ([current-environment-variables complete-env])
        (release-update-artifact (release-update-environment #t)
                                 appimage-project archive
                                 #:platform 'linux
                                 #:architecture 'x64)))
    (check-equal? (update-artifact-installer appimage-artifact) 'appimage)
    (check-equal? (update-artifact-size appimage-artifact)
                  (file-size appimage))
    (check-true
     (string-suffix? (update-artifact-url appimage-artifact)
                     (path->string (file-name-from-path appimage))))

    (define deb-only-project
      (rivet-project temp-root
                     #hasheq((name . "Example")
                             (version . "2.3.4")
                             (linux-formats . ("deb")))))
    (define fallback-artifact
      (parameterize ([current-environment-variables complete-env])
        (release-update-artifact (release-update-environment #t)
                                 deb-only-project archive
                                 #:platform 'linux
                                 #:architecture 'x64)))
    (check-equal? (update-artifact-installer fallback-artifact) 'zip))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
