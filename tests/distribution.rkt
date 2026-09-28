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

(define private-key (generate-private-key 'eddsa '((curve ed25519))))
(define public-key
  (datum->pk-key (pk-key->datum private-key 'SubjectPublicKeyInfo)
                 'SubjectPublicKeyInfo))
(define sample-artifact
  (update-artifact 'windows 'x64 "https://updates.example/app.msi"
                   (make-string 64 #\a) 4 'msi '("/quiet")))
(define sample-manifest
  (update-manifest "dev.rivet.test" "1.2.0" 12 'stable
                   "2026-09-28T00:00:00Z" "1.0.0" "1.1.0"
                   #t 100 (list sample-artifact)))

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
