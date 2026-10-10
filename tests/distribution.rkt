#lang racket/base

(require crypto
         crypto/all
         json
         rackunit
         racket/file
         racket/port
         "../rivet/distribution.rkt")

(use-all-factories!)

(check-true (version<? "1.2.3-alpha.1" "1.2.3"))
(check-true (version<? "1.2.3+build.1" "1.2.4"))
(check-true (version=? "1.2.3+first" "1.2.3+second"))
(check-false (version? "01.2.3"))
(check-false (version? "1.2.3-beta.01"))
(check-true (channel-accepts-version? 'stable "1.0.0"))
(check-false (channel-accepts-version? 'stable "1.0.0-beta.1"))
(check-true (channel-accepts-version? 'beta "1.0.0-beta.1"))
(check-true (channel-accepts-version? 'dev "1.0.0-nightly.5"))

(define ed25519-impl
  (get-pk 'eddsa (list libcrypto-factory sodium-factory decaf-factory)))
(define private-key
  (and ed25519-impl
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (generate-private-key ed25519-impl '((curve ed25519))))))
(unless private-key
  (printf "Rivet distribution tests: compatible Ed25519 provider unavailable; signature integration is covered on Windows and macOS CI\n"))

(define sample-artifact
  (update-artifact 'windows 'x64 "https://updates.example/app.msi"
                   (make-string 64 #\a) 4 'msi '("/quiet")))
(define sample-manifest
  (update-manifest "dev.rivet.test" "1.2.0" 12 'stable
                   "2026-09-28T00:00:00Z" "1.0.0" "1.1.0"
                   #t 100 (list sample-artifact)))

(when private-key
  (define public-key
    (datum->pk-key (pk-key->datum private-key 'SubjectPublicKeyInfo)
                   'SubjectPublicKeyInfo))
  (define signed-out (open-output-bytes))
  (write-signed-manifest sample-manifest private-key "release-2026" signed-out)
  (define signed-bytes (get-output-bytes signed-out))
  (define verified
    (verify-signed-manifest (open-input-bytes signed-bytes)
                            public-key
                            #:key-id "release-2026"))
  (check-equal? (update-manifest-version verified) "1.2.0")
  (check-equal? (update-artifact-installer
                 (car (update-manifest-artifacts verified)))
                'msi)

;; Any payload mutation is rejected even when the changed JSON remains valid.
  (define wrapper (read-json (open-input-bytes signed-bytes)))
  (define payload (base64-string->bytes (hash-ref wrapper 'payload)))
  (define tampered-payload
    (bytes-append payload #" "))
  (define tampered-wrapper
    (hash-set wrapper 'payload (bytes->base64-string tampered-payload)))
  (define tampered-out (open-output-bytes))
  (write-json tampered-wrapper tampered-out)
  (check-exn #rx"signature verification failed"
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes (get-output-bytes tampered-out)) public-key)))

  (define config
    (updater-config "dev.rivet.test" "1.1.0" 'stable 'windows 'x64
                    public-key "release-2026" 0 (* 1024 1024)))
  (check-true (update-candidate? (select-update config sample-manifest)))
  (check-false
   (select-update (struct-copy updater-config config [current-version "1.2.0"])
                  sample-manifest))
  (check-false
   (select-update (struct-copy updater-config config [rollout-bucket 75])
                  (struct-copy update-manifest sample-manifest [rollout 50])))

;; The DER SPKI bytes a release build embeds as hex in app source parse
;; into a verifying key without a round-trip through a temp file.
  (define embedded-der (pk-key->datum private-key 'SubjectPublicKeyInfo))
  (define embedded-public (bytes->ed25519-public-key embedded-der))
  (check-true (pk-key? embedded-public))
  (check-true (ed25519-verify embedded-public #"payload"
                              (ed25519-sign private-key #"payload")))
  (check-exn #rx"could not decode Ed25519 key"
             (lambda () (bytes->ed25519-public-key #"not a key"))))

(define artifact-file (make-temporary-file "rivet-artifact-~a.bin"))
(dynamic-wind
  void
  (lambda ()
    (call-with-output-file artifact-file
      #:exists 'truncate/replace #:mode 'binary
      (lambda (out) (write-bytes #"test" out)))
    (define matching
      (struct-copy update-artifact sample-artifact
                   [sha256 (sha256-file/hex artifact-file)]))
    (define candidate
      (update-candidate
       (struct-copy update-manifest sample-manifest [artifacts (list matching)])
       matching))
    (check-equal? (verify-update-artifact! candidate artifact-file) artifact-file)
    (call-with-output-file artifact-file #:exists 'append #:mode 'binary
      (lambda (out) (write-byte 0 out)))
    (check-exn #rx"size does not match"
               (lambda () (verify-update-artifact! candidate artifact-file))))
  (lambda () (when (file-exists? artifact-file) (delete-file artifact-file))))

(define installed? #f)
(define rolled-back? #f)
(define plan
  (make-install-plan
   (update-candidate sample-manifest sample-artifact) "download.msi"
   #:install (lambda (_) (set! installed? #t) (error 'installer "failed"))
   #:rollback (lambda () (set! rolled-back? #t))))
(check-exn #rx"failed" (lambda () (execute-install-plan! plan)))
(check-true installed?)
(check-true rolled-back?)

;; A successful plan preserves the restart callback's result and commits only
;; after the replacement passes its health check.
(define successful-calls '())
(define successful-plan
  (make-install-plan
   (update-candidate sample-manifest sample-artifact) "download.msi"
   #:install (lambda (_) (set! successful-calls (cons 'install successful-calls)))
   #:restart (lambda ()
               (set! successful-calls (cons 'restart successful-calls))
               'restart-result)
   #:rollback (lambda ()
                (set! successful-calls (cons 'rollback successful-calls)))))
(check-equal?
 (execute-install-plan!
  successful-plan
 #:health-check
  (lambda ()
    (set! successful-calls (cons 'health successful-calls))
    #t)
  #:commit
  (lambda ()
    (set! successful-calls (cons 'commit successful-calls))))
 'restart-result)
(check-equal? (reverse successful-calls) '(install restart health commit))

;; Health is part of the transaction rather than an informational callback:
;; a replacement that starts but is not healthy rolls back.
(define unhealthy-rolled-back? #f)
(define unhealthy-plan
  (make-install-plan
   (update-candidate sample-manifest sample-artifact) "download.msi"
   #:install void
   #:rollback (lambda () (set! unhealthy-rolled-back? #t))))
(check-exn #rx"failed its health check"
           (lambda ()
             (execute-install-plan! unhealthy-plan
                                    #:health-check (lambda () #f))))
(check-true unhealthy-rolled-back?)

;; A non-local exit models interruption after installation and before the
;; replacement has returned. The durable journal survives and the next process
;; can roll back the exact same plan. A different plan is rejected.
(define journal-root (make-temporary-file "rivet-install-journal-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define journal-path (build-path journal-root "transaction.json"))
    (define recovery-rolled-back? #f)
    (define escape #f)
    (define interrupted-plan
      (make-install-plan
       (update-candidate sample-manifest sample-artifact)
       (build-path journal-root "download.msi")
       #:backup-path (build-path journal-root "backup")
       #:install void
       #:restart (lambda () (escape 'interrupted))
       #:rollback (lambda () (set! recovery-rolled-back? #t))))
    (check-equal?
     (call-with-current-continuation
      (lambda (return)
        (set! escape return)
        (execute-install-plan! interrupted-plan #:journal-path journal-path)))
     'interrupted)
    (check-true (file-exists? journal-path))
    (check-equal?
     (hash-ref (call-with-input-file journal-path read-json) 'phase)
     "restarting")

    (define mismatched-plan
      (make-install-plan
       (update-candidate sample-manifest sample-artifact)
       (build-path journal-root "different.msi")
       #:install void))
    (check-exn #rx"does not match the plan"
               (lambda ()
                 (recover-install-plan! mismatched-plan journal-path)))
    (check-true (file-exists? journal-path))

    (check-equal? (recover-install-plan! interrupted-plan journal-path)
                  'rolled-back)
    (check-true recovery-rolled-back?)
    (check-false (file-exists? journal-path))

    (define success-journal (build-path journal-root "success.json"))
    (check-equal?
     (execute-install-plan! successful-plan
                            #:health-check (lambda () #t)
                            #:journal-path success-journal)
     'restart-result)
    (check-false (file-exists? success-journal))

    ;; Signed policy can forbid rollback. The journal remains available for
    ;; diagnosis instead of claiming a recovery that did not occur.
    (define no-rollback-journal (build-path journal-root "no-rollback.json"))
    (define no-rollback-plan
      (make-install-plan
       (update-candidate
        (struct-copy update-manifest sample-manifest [rollback-allowed? #f])
        sample-artifact)
       (build-path journal-root "no-rollback.msi")
       #:install (lambda (_) (error 'installer "no rollback"))))
    (check-exn #rx"no rollback"
               (lambda ()
                 (execute-install-plan! no-rollback-plan
                                        #:journal-path no-rollback-journal)))
    (check-true (file-exists? no-rollback-journal))
    (check-exn #rx"cannot be rolled back"
               (lambda ()
                 (recover-install-plan! no-rollback-plan no-rollback-journal)))
    (delete-file no-rollback-journal)

    ;; A rollback that was itself interrupted remains retryable. Recovery
    ;; records the failed phase and invokes the same idempotent callback again.
    (define retry-journal (build-path journal-root "retry.json"))
    (define rollback-attempts 0)
    (define retry-plan
      (make-install-plan
       (update-candidate sample-manifest sample-artifact)
       (build-path journal-root "retry.msi")
       #:install (lambda (_) (error 'installer "install failed"))
       #:rollback
       (lambda ()
         (set! rollback-attempts (add1 rollback-attempts))
         (when (= rollback-attempts 1)
           (error 'rollback "first rollback failed")))))
    (check-exn #rx"install failed; rollback also failed: rollback: first rollback failed"
               (lambda ()
                 (execute-install-plan! retry-plan #:journal-path retry-journal)))
    (check-equal?
     (hash-ref (call-with-input-file retry-journal read-json) 'phase)
     "rollback-failed")
    (check-equal? (recover-install-plan! retry-plan retry-journal) 'rolled-back)
    (check-equal? rollback-attempts 2)
    (check-false (file-exists? retry-journal)))
  (lambda () (delete-directory/files journal-root)))

;; Commit is its own durable phase. If a process stops after health but while
;; deleting its backup, recovery repeats the idempotent commit instead of
;; rolling a healthy replacement back.
(define commit-root (make-temporary-file "rivet-install-commit-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define journal-path (build-path commit-root "transaction.json"))
    (define escape #f)
    (define commits 0)
    (check-equal?
     (call-with-current-continuation
      (lambda (return)
        (set! escape return)
        (execute-install-plan!
         successful-plan
         #:journal-path journal-path
         #:commit
         (lambda ()
           (set! commits (add1 commits))
           (escape 'commit-interrupted)))))
     'commit-interrupted)
    (check-equal?
     (hash-ref (call-with-input-file journal-path read-json) 'phase)
     "committing")
    (check-equal?
     (recover-install-plan!
      successful-plan journal-path
      #:commit (lambda () (set! commits (add1 commits))))
     'committed)
    (check-equal? commits 2)
    (check-false (file-exists? journal-path)))
  (lambda () (delete-directory/files commit-root)))
