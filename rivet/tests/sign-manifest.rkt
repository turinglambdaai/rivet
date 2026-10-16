#lang racket/base

;; Sign-manifest CLI end to end: keygen, sign from named artifacts, verify
;; with the public half, sidecar emission, and the fail-closed publish that
;; deletes the output when verification fails.

(require rackunit
         racket/file
         racket/path
         crypto
         crypto/all
         "../../rivet/distribution/crypto.rkt"
         "../../rivet/distribution/manifest.rkt"
         "../../rivet-cli/sign-manifest.rkt")

(use-all-factories!)

(define ed25519-impl
  (get-pk 'eddsa (list libcrypto-factory sodium-factory decaf-factory)))
(define private-key
  (and ed25519-impl
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (generate-private-key ed25519-impl '((curve ed25519))))))

(unless private-key
  (displayln
   "rivet-sign-manifest-tests: skipping; no compatible Ed25519 provider")
  (exit 0))

(define root (make-temporary-file "rivet-sign-manifest-~a" 'directory))
(define private-key-path (build-path root "private.der"))
(define public-key-path (build-path root "public.der"))
(call-with-output-file private-key-path
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (pk-key->datum private-key 'PrivateKeyInfo) out)))
(call-with-output-file public-key-path
  #:exists 'truncate/replace
  (lambda (out)
    (write-bytes (pk-key->datum private-key 'SubjectPublicKeyInfo) out)))

;; --- argument parsing ------------------------------------------------------

(define-values (parsed-artifacts parsed-options)
  (parse-sign-manifest-arguments
   (list "--application-id" "dev.example"
         "--version" "1.2.3" "--build" "7" "--channel" "stable"
         "--base-url" "https://dl.example/app/"
         "--key-id" "release-2026"
         "--artifact" "macos:arm64:zip:App-1.2.3.zip")))
(check-equal? (length parsed-artifacts) 1)
(check-equal? (hash-ref parsed-options 'application-id) "dev.example")
(check-equal? (hash-ref parsed-options 'build) 7)
(check-equal? (hash-ref parsed-options 'channel) 'stable)

(check-exn #rx"--artifact expects"
           (lambda () (parse-sign-manifest-arguments (list "--artifact" "macos:arm64:zip"))))
(check-exn #rx"artifact installer must be"
           (lambda () (parse-sign-manifest-arguments (list "--artifact" "macos:arm64:exe:App.zip"))))
(check-exn #rx"--base-url must be an HTTPS URL"
           (lambda () (parse-sign-manifest-arguments (list "--base-url" "http://dl.example/"))))
(check-exn #rx"unknown argument"
           (lambda () (parse-sign-manifest-arguments (list "--bogus"))))
(check-exn #rx"at least one --artifact"
           (lambda ()
             (sign-manifest! '()
                             (hasheq 'application-id "d" 'version "1" 'build 1
                                     'channel 'stable 'base-url "https://x/"
                                     'key-id "k" 'private-key (path->string private-key-path)))))

;; --- signing end to end ----------------------------------------------------

(define artifact (build-path root "App-1.2.3-macos-arm64.zip"))
(call-with-output-file artifact
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 2048 7) out)))

(define output
  (sign-manifest!
   (list (requested-artifact 'macos 'arm64 'zip (path->string artifact)))
   (hasheq 'application-id "dev.example"
           'version "1.2.3"
           'build 7
           'channel 'stable
           'base-url "https://dl.example/app/"
           'key-id "release-2026"
           'private-key (path->string private-key-path)
           'public-key (path->string public-key-path)
           'output (path->string (build-path root "update.json"))
           'sidecars? #t
           'published-at "2026-10-16T00:00:00Z")))
(check-true (file-exists? output))

;; The published feed verifies with the public half and carries the exact
;; artifact facts.
(define manifest
  (call-with-input-file output
    (lambda (in) (verify-signed-manifest in (read-ed25519-public-key public-key-path)))))
(check-equal? (update-manifest-application-id manifest) "dev.example")
(check-equal? (length (update-manifest-artifacts manifest)) 1)
(define entry (car (update-manifest-artifacts manifest)))
(check-equal? (update-artifact-url entry)
              (format "https://dl.example/app/~a"
                      (path->string (file-name-from-path artifact))))
(check-equal? (update-artifact-size entry) 2048)
(check-equal? (update-artifact-sha256 entry) (sha256-file/hex artifact))

;; Sidecars landed next to the artifact in bsdtar's conventional format.
(define sidecar (path-add-extension artifact #".sha256"))
(check-true (file-exists? sidecar))
(check-regexp-match
 #rx"^[0-9a-f]{64}  App-1\\.2\\.3-macos-arm64\\.zip$"
 (file->string sidecar))

;; --- fail-closed publish ---------------------------------------------------

;; A wrong public key deletes the output instead of leaving an unverified
;; feed on disk.
(define wrong-public (build-path root "wrong.der"))
(call-with-output-file wrong-public
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 44 3) out)))
(define other-artifact (build-path root "Other-1.0.0-linux-x64.zip"))
(call-with-output-file other-artifact
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 128 9) out)))
(define other-output (build-path root "other-update.json"))
(check-exn #rx"verification failed|unexpected key|malformed"
           (lambda ()
             (sign-manifest!
              (list (requested-artifact 'linux 'x64 'zip (path->string other-artifact)))
              (hasheq 'application-id "dev.example"
                      'version "1.0.0"
                      'build 1
                      'channel 'stable
                      'base-url "https://dl.example/other/"
                      'key-id "release-2026"
                      'private-key (path->string private-key-path)
                      'public-key (path->string wrong-public)
                      'output (path->string other-output)))))
(check-false (file-exists? other-output))

(delete-directory/files root)
