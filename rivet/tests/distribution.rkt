#lang racket/base

(require crypto
         crypto/all
         json
         rackunit
         racket/file
         racket/port
         "../../rivet/distribution.rkt"
         (rename-in (submod "../../rivet/distribution/updater.rkt" test)
                    [copy-limited! copy-limited!/test]
                    [call-with-partial-cleanup
                     call-with-partial-cleanup/test]
                    [call-with-fetch-deadline
                     call-with-fetch-deadline/test]))

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

(check-equal? (platform-symbol 'windows) 'windows)
(check-equal? (platform-symbol 'macosx) 'macos)
(check-equal? (platform-symbol 'unix) 'linux)
(check-exn #rx"unsupported operating system"
           (lambda () (platform-symbol 'plan9)))
(check-equal? (architecture-symbol 'x86_64) 'x64)
(check-equal? (architecture-symbol 'amd64) 'x64)
(check-equal? (architecture-symbol 'aarch64) 'arm64)
(check-equal? (architecture-symbol 'arm64) 'arm64)
(check-exn #rx"unsupported architecture"
           (lambda () (architecture-symbol 'riscv64)))
(check-equal? (installer-extension 'zip) ".zip")
(check-equal? (installer-extension 'targz) ".tar.gz")
(check-equal? (installer-extension 'appimage) ".AppImage")
(check-exn #rx"unsupported installer kind"
           (lambda () (installer-extension 'unknown)))
(check-equal? (rfc3339-now 0) "1970-01-01T00:00:00Z")

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

(define linux-config
  (updater-config "dev.rivet.test" "1.1.0" 'stable 'linux 'x64
                  #f #f 0 (* 1024 1024)))
(define linux-zip
  (update-artifact 'linux 'x64 "https://updates.example/app.zip"
                   (make-string 64 #\b) 4 'zip '()))
(define linux-appimage
  (update-artifact 'linux 'x64 "https://updates.example/app.AppImage"
                   (make-string 64 #\c) 4 'appimage '()))
(define linux-manifest
  (struct-copy update-manifest sample-manifest
               [artifacts (list linux-zip linux-appimage)]))
(check-eq? (update-candidate-artifact
            (select-update linux-config linux-manifest
                           #:install-kind 'portable))
           linux-zip)
(check-eq? (update-candidate-artifact
            (select-update linux-config linux-manifest
                           #:install-kind 'appimage))
           linux-appimage)
(check-false (select-update linux-config linux-manifest
                            #:install-kind 'package-manager))
(check-exn exn:fail:contract?
           (lambda ()
             (select-update linux-config linux-manifest
                            #:install-kind 'unknown)))

(define windows-config
  (updater-config "dev.rivet.test" "1.1.0" 'stable 'windows 'x64
                  #f #f 0 (* 1024 1024)))
(define windows-zip
  (update-artifact 'windows 'x64 "https://updates.example/app.zip"
                   (make-string 64 #\d) 4 'zip '()))
(define windows-manifest
  (struct-copy update-manifest sample-manifest
               [artifacts (list windows-zip sample-artifact)]))
(check-eq? (update-candidate-artifact
            (select-update windows-config windows-manifest
                           #:install-kind 'portable))
           windows-zip)
(check-eq? (update-candidate-artifact
            (select-update windows-config windows-manifest
                           #:install-kind 'msi))
           sample-artifact)

(check-exn exn:fail:contract?
           (lambda ()
             (download-update linux-config
                              (update-candidate linux-manifest linux-zip)
                              "unused"
                              #:on-progress (lambda () (void)))))
(check-exn exn:fail:contract?
           (lambda ()
             (download-update linux-config
                              (update-candidate linux-manifest linux-zip)
                              "unused"
                              #:progress-every 0)))

;; A signed policy must describe at least one possible upgrade path. Reject
;; contradictions while parsing and, through write-signed-manifest's round
;; trip, before a publisher can sign them.
(define (check-invalid-manifest manifest expected-message)
  (check-exn expected-message
             (lambda ()
               (payload-bytes->manifest
                (manifest->payload-bytes manifest)))))

(check-invalid-manifest
 (struct-copy update-manifest sample-manifest [artifacts '()])
 #rx"non-empty array")
(check-invalid-manifest
 (struct-copy update-manifest sample-manifest [minimum-version "1.2.0"])
 #rx"minimum_version must be older")
(check-invalid-manifest
 (struct-copy update-manifest sample-manifest [previous-version "1.2.0"])
 #rx"previous_version must be older")
(check-invalid-manifest
 (struct-copy update-manifest sample-manifest
              [artifacts
               (list sample-artifact
                     (struct-copy update-artifact sample-artifact
                                  [url "https://mirror.example/app.msi"]))])
 #rx"duplicate artifact")
(check-invalid-manifest
 (struct-copy update-manifest sample-manifest
              [artifacts
               (list (struct-copy update-artifact sample-artifact [size 0]))])
 #rx"positive integer")

(define sample-payload-jsexpr
  (read-json (open-input-bytes (manifest->payload-bytes sample-manifest))))
(define unknown-field-out (open-output-bytes))
(write-json (hash-set sample-payload-jsexpr 'versoin "1.2.0")
            unknown-field-out)
(check-exn #rx"fields outside its schema"
           (lambda ()
             (payload-bytes->manifest
              (get-output-bytes unknown-field-out))))
(check-exn #rx"exactly one JSON value"
           (lambda ()
             (payload-bytes->manifest
              (bytes-append (manifest->payload-bytes sample-manifest)
                            #" {}"))))

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

  ;; Unauthenticated payload bytes never reach the JSON/manifest parser. A
  ;; malformed payload with a well-formed but mismatched signature must fail at
  ;; the cryptographic boundary, not disclose a downstream parse diagnostic.
  (define untrusted-out (open-output-bytes))
  (write-json
   (hasheq
    'schema manifest-schema-version
    'payload (bytes->base64-string #"not JSON")
    'signature
    (hasheq
     'algorithm "ed25519"
     'key_id "release-2026"
     'value
     (bytes->base64-string
      (ed25519-sign private-key #"different authenticated payload"))))
   untrusted-out)
  (check-exn #rx"signature verification failed"
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes (get-output-bytes untrusted-out))
                public-key
                #:key-id "release-2026")))

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

;; download-update's private copy path streams the payload, enforces the byte
;; limit, and reports a useful zero-to-final sequence without flooding the
;; callback. A payload larger than the copy buffer makes the cadence assertion
;; exercise multiple reads instead of passing vacuously on one read.
(let* ([payload (apply bytes (for/list ([i (in-range 200000)]) (modulo i 256)))]
       [in (open-input-bytes payload)]
       [out (open-output-bytes)]
       [reports '()])
  (define total
    (copy-limited!/test in out (* 1024 1024)
                        #:on-progress
                        (lambda (n) (set! reports (cons n reports)))
                        #:progress-every 100000))
  (check-equal? total 200000)
  (check-equal? (get-output-bytes out) payload)
  (check-equal? (reverse reports) '(0 131072 200000)))

(let ([in (open-input-bytes (make-bytes 10))]
      [out (open-output-bytes)])
  ;; The limit is enforced before the offending chunk is written.
  (check-exn #rx"permitted byte limit"
             (lambda ()
               (copy-limited!/test in out 5)))
  (check-equal? (bytes-length (get-output-bytes out)) 0))

;; Cancellation uses exn:break rather than exn:fail. It must still remove the
;; partial download before the worker publishes its terminal state.
(define interrupted-partial
  (make-temporary-file "rivet-interrupted-download-~a.partial"))
(check-exn
 exn:break?
 (lambda ()
   (call-with-partial-cleanup/test
    interrupted-partial
    (lambda ()
      (let/ec escape
        (raise (exn:break "cancelled"
                          (current-continuation-marks)
                          escape)))))))
(check-false (file-exists? interrupted-partial))

;; Stalled and slow peers must raise instead of parking the backend serve
;; thread forever (#249/#253). The stall case holds a pipe open without
;; writing; the total case drips bytes fast enough to defeat the stall bound
;; but slow enough to hit the overall cap.
(define-values (stall-in stall-out) (make-pipe))
(let ([values stall-in]
      [out (open-output-bytes)])
  (check-exn #rx"download stalled: no bytes for 0.2 seconds"
             (lambda ()
               (copy-limited!/test values out (* 1024 1024)
                                   #:stall-seconds 0.2)))
  (close-input-port values)
  (close-output-port stall-out))

(define-values (drip-in drip-out) (make-pipe))
(let ([values drip-in]
      [out (open-output-bytes)]
      [writer (void)])
  (set! writer
        (thread
         (lambda ()
           (let loop ([i 0])
             (when (< i 200)
               (write-byte 65 drip-out)
               (flush-output drip-out)
               (sleep 0.03)
               (loop (add1 i)))))))
  (define total-outcome
    (call-with-values
     (lambda ()
       (with-handlers
           ([exn:fail? (lambda (e) (printf "DBG total raised: ~a\n" (exn-message e)) 'raised)])
         (copy-limited!/test values out (* 1024 1024)
                             #:stall-seconds 0.5
                             #:total-seconds 0.3)))
     list))
  (printf "DBG total outcome: ~s\n" total-outcome)
  (check-equal? (length total-outcome) 1)
  (kill-thread writer)
  (close-input-port values)
  (close-output-port drip-out))

;; The manifest fetch wraps the blocking connect in a custodian-owned
;; worker; a deadline past connect + idle must kill it and raise instead of
;; parking the caller on a black-holed peer.
(check-exn #rx"update fetch exceeded its 0\\.3[0-9]* second deadline"
           (lambda ()
             (call-with-fetch-deadline/test
              'fetch-update-manifest 0.1 0.2
              (lambda () (sync never-evt) (error "unreachable")))))
(check-equal?
 (call-with-fetch-deadline/test
  'fetch-update-manifest 0.1 0.2 (lambda () 'completed))
 'completed)
