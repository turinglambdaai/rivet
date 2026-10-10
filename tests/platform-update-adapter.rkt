#lang racket/base

(require file/zip
         json
         rackunit
         racket/file
         racket/path
         racket/port
         "../rivet/distribution.rkt")

(define platform (current-update-platform))

(define (candidate installer [version "2.0.0"])
  (define artifact
    (update-artifact platform 'x64 "https://updates.example/application.zip"
                     (make-string 64 #\a) 1 installer '()))
  (update-candidate
   (update-manifest "dev.rivet.adapter-test" version 2 'stable
                    "2026-10-10T00:00:00Z" "1.0.0" "1.0.0"
                    #t 100 (list artifact))
   artifact))

(define (write-text path value)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display value out))))

(define (read-text path)
  (call-with-input-file path port->string))

(define (make-update-archive root value)
  (define payload (build-path root "payload"))
  (define archive (build-path root "update.zip"))
  (when (directory-exists? payload) (delete-directory/files payload))
  (when (file-exists? archive) (delete-file archive))
  (write-text (build-path payload "version.txt") value)
  (parameterize ([current-directory root])
    (zip archive "payload"))
  archive)

(define (test-verifier expected)
  (lambda (payload)
    (check-equal? (read-text (build-path payload "version.txt")) expected)))

(check-equal? (platform-installer-policy 'windows 'zip) 'portable)
(check-equal? (platform-installer-policy 'windows 'msi) 'package-manager)
(check-equal? (platform-installer-policy 'macos 'dmg) 'package-manager)
(check-equal? (platform-installer-policy 'linux 'appimage) 'portable)
(check-equal? (platform-installer-policy 'linux 'deb) 'package-manager)
(check-equal? (platform-installer-policy 'linux 'rpm) 'package-manager)
(check-equal? (platform-installer-policy 'linux 'unknown) 'unsupported)

(define root (make-temporary-file "rivet-platform-update-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    ;; Successful replacement is committed only after restart and health. Its
    ;; previous payload, staging directory, marker, and journal are removed.
    (define success-root (build-path root "success"))
    (make-directory success-root)
    (define success-target (build-path success-root "installed"))
    (write-text (build-path success-target "version.txt") "old")
    (define success-archive (make-update-archive success-root "new"))
    (define success-journal (build-path success-root "transaction.json"))
    (define restarted? #f)
    (define success
      (prepare-platform-installation
       (candidate 'zip) success-archive
       #:target success-target
       #:restart (lambda () (set! restarted? #t) 'restarted)
       #:health-check
       (lambda ()
         (string=? (read-text (build-path success-target "version.txt"))
                   "new"))
       #:verify-staged (test-verifier "new")))
    (check-equal?
     (execute-platform-installation! success #:journal-path success-journal)
     'restarted)
    (check-true restarted?)
    (check-equal? (read-text (build-path success-target "version.txt")) "new")
    (check-false (file-exists? success-journal))
    (check-false (directory-exists?
                  (string->path
                   (string-append (path->string success-target)
                                  ".rivet-backup"))))

    ;; A failed health check restores the previous application byte-for-byte.
    (define unhealthy-root (build-path root "unhealthy"))
    (make-directory unhealthy-root)
    (define unhealthy-target (build-path unhealthy-root "installed"))
    (write-text (build-path unhealthy-target "version.txt") "healthy-old")
    (define unhealthy-archive (make-update-archive unhealthy-root "bad-new"))
    (define unhealthy
      (prepare-platform-installation
       (candidate 'zip "2.0.1") unhealthy-archive
       #:target unhealthy-target
       #:restart void
       #:health-check (lambda () #f)
       #:verify-staged (test-verifier "bad-new")))
    (check-exn #rx"failed its health check"
               (lambda () (execute-platform-installation! unhealthy)))
    (check-equal?
     (read-text (build-path unhealthy-target "version.txt")) "healthy-old")

    ;; Verification happens before the old target moves.
    (define rejected-root (build-path root "rejected"))
    (make-directory rejected-root)
    (define rejected-target (build-path rejected-root "installed"))
    (write-text (build-path rejected-target "version.txt") "trusted")
    (define rejected-archive (make-update-archive rejected-root "untrusted"))
    (define rejected
      (prepare-platform-installation
       (candidate 'zip "2.0.2") rejected-archive
       #:target rejected-target
       #:restart void
       #:health-check (lambda () #t)
       #:verify-staged (lambda (_) (error 'signature "invalid"))))
    (check-exn #rx"invalid"
               (lambda () (execute-platform-installation! rejected)))
    (check-equal? (read-text (build-path rejected-target "version.txt"))
                  "trusted")

    ;; Recovery reconstructs the same plan in a new process and rolls back an
    ;; interruption after replacement but before restart completed.
    (define recovery-root (build-path root "recovery"))
    (make-directory recovery-root)
    (define recovery-target (build-path recovery-root "installed"))
    (write-text (build-path recovery-target "version.txt") "before-crash")
    (define recovery-archive (make-update-archive recovery-root "after-crash"))
    (define recovery-journal (build-path recovery-root "transaction.json"))
    (define escape #f)
    (define interrupted
      (prepare-platform-installation
       (candidate 'zip "2.0.3") recovery-archive
       #:target recovery-target
       #:restart (lambda () (escape 'process-stopped))
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "after-crash")))
    (check-equal?
     (call-with-current-continuation
      (lambda (return)
        (set! escape return)
        (execute-platform-installation! interrupted
                                        #:journal-path recovery-journal)))
     'process-stopped)
    (check-equal? (read-text (build-path recovery-target "version.txt"))
                  "after-crash")
    (check-equal?
     (hash-ref (call-with-input-file recovery-journal read-json) 'phase)
     "restarting")
    (define reconstructed
      (prepare-platform-installation
       (candidate 'zip "2.0.3") recovery-archive
       #:target recovery-target
       #:restart void
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "after-crash")))
    (check-equal?
     (recover-platform-installation! reconstructed recovery-journal)
     'rolled-back)
    (check-equal? (read-text (build-path recovery-target "version.txt"))
                  "before-crash")

    ;; First-install rollback uses a durable marker, so it removes the failed
    ;; replacement without inventing a nonexistent previous target.
    (define first-root (build-path root "first-install"))
    (make-directory first-root)
    (define first-target (build-path first-root "installed"))
    (define first-archive (make-update-archive first-root "first"))
    (define first-install
      (prepare-platform-installation
       (candidate 'zip "2.0.4") first-archive
       #:target first-target
       #:restart (lambda () (error 'restart "failed"))
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "first")))
    (check-exn #rx"restart: failed"
               (lambda () (execute-platform-installation! first-install)))
    (check-false (directory-exists? first-target))

    ;; Managed installers cannot be smuggled through the portable path.
    (define managed-installer
      (case platform
        [(windows) 'msi]
        [(macos) 'dmg]
        [(linux) 'deb]))
    (check-exn
     #rx"owned by the operating-system package manager"
     (lambda ()
       (prepare-platform-installation
        (candidate managed-installer "2.0.5") success-archive
        #:target (build-path root "managed-target")
        #:restart void
        #:health-check (lambda () #t)))))
  (lambda () (delete-directory/files root)))
