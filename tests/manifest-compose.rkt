#lang racket/base

(require rackunit
         json
         racket/file
         racket/path
         racket/runtime-path
         racket/system
         crypto
         crypto/all
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/manifest.rkt"
         "../rivet-cli/manifest-compose.rkt")

(use-all-factories!)

(define-runtime-path cli-main "../rivet-cli/main.rkt")

(define temp-root (make-temporary-file "rivet-manifest-compose-~a" 'directory))

(define (artifact platform architecture url)
  (update-artifact platform architecture url (make-string 64 #\a) 1 'msi '()))
(define (manifest #:artifacts artifacts #:version [version "1.4.0"])
  (update-manifest "dev.rivet.smoke" version 7 'stable
                   "2026-10-09T10:00:00Z" "0.0.0" #f #t 100 artifacts))

(define ed25519-impl
  (get-pk 'eddsa (list libcrypto-factory sodium-factory decaf-factory)))
(define private-key
  (and ed25519-impl
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (generate-private-key ed25519-impl '((curve ed25519))))))

(unless private-key
  (error 'manifest-compose-tests
         "a compatible Ed25519 provider is required for these tests"))

(define (write-manifest! path m [key-id "family-key"])
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (write-signed-manifest m private-key key-id out))))

(define-values (parsed-inputs parsed-output)
  (parse-manifest-compose-arguments
   '("windows.json" "--output" "family.json" "macos.json")))
(check-equal? parsed-inputs
              (map string->path '("windows.json" "macos.json")))
(check-equal? parsed-output (string->path "family.json"))
(check-exn #rx"requires a destination"
           (lambda ()
             (parse-manifest-compose-arguments '("windows.json" "--output"))))
(check-exn #rx"unknown option"
           (lambda ()
             (parse-manifest-compose-arguments '("windows.json" "--wat"))))
(check-exn #rx"only once"
           (lambda ()
             (parse-manifest-compose-arguments
              '("windows.json" "--output" "one.json"
                "--output" "two.json"))))

(dynamic-wind
  void
  (lambda ()
    (define windows-manifest
      (build-path temp-root "update-windows.json"))
    (write-manifest! windows-manifest
                     (manifest #:artifacts (list (artifact 'windows 'x64 "https://updates.example/w.msi"))))
    (define macos-manifest
      (build-path temp-root "update-macos.json"))
    (write-manifest! macos-manifest
                     (manifest
                      #:artifacts
                      (list (artifact 'macos 'arm64 "https://updates.example/m-arm64.dmg")
                            (artifact 'macos 'x64 "https://updates.example/m-x64.dmg"))))
    (define linux-manifest
      (build-path temp-root "update-linux.json"))
    (write-manifest! linux-manifest
                     (manifest #:artifacts (list (artifact 'linux 'arm64 "https://updates.example/l.AppImage"))))

    (define composed-path (build-path temp-root "update-family.json"))
    (define output
      (compose-manifests! (list windows-manifest macos-manifest linux-manifest)
                          composed-path
                          #:private-key private-key
                          #:key-id "family-key"))
    (check-equal? output composed-path)

    (define-values (composed _payload key-id _signature)
      (call-with-input-file composed-path
        (lambda (in) (read-signed-manifest in))))
    (check-equal? (update-manifest-application-id composed) "dev.rivet.smoke")
    (check-equal? (update-manifest-version composed) "1.4.0")
    (check-equal? (length (update-manifest-artifacts composed)) 4)
    (check-equal?
     (map update-artifact-url (update-manifest-artifacts composed))
     '("https://updates.example/w.msi" "https://updates.example/m-arm64.dmg" "https://updates.example/m-x64.dmg" "https://updates.example/l.AppImage"))
    (check-equal? key-id "family-key")

    ;; Exercise the public command boundary as well as the pure parser. In
    ;; particular, --output may appear between inputs and must not become an
    ;; input path itself.
    (define private-key-path (build-path temp-root "private-key.der"))
    (call-with-output-file private-key-path
      #:exists 'truncate/replace
      (lambda (out)
        (write-bytes (pk-key->datum private-key 'PrivateKeyInfo) out)))
    (define cli-output (build-path temp-root "update-family-cli.json"))
    (define cli-environment
      (environment-variables-copy (current-environment-variables)))
    (environment-variables-set!
     cli-environment
     #"RIVET_UPDATE_PRIVATE_KEY"
     (path->bytes private-key-path))
    (environment-variables-set!
     cli-environment
     #"RIVET_UPDATE_KEY_ID"
     #"family-key")
    (define racket-executable
      (or (find-executable-path "racket")
          (error 'manifest-compose-tests "could not find the racket executable")))
    (define cli-stdout-path (build-path temp-root "cli-stdout.txt"))
    (define cli-stderr-path (build-path temp-root "cli-stderr.txt"))
    (define cli-status
      (call-with-output-file cli-stdout-path
        #:exists 'truncate/replace
        (lambda (stdout)
          (call-with-output-file cli-stderr-path
            #:exists 'truncate/replace
            (lambda (stderr)
              (parameterize ([current-environment-variables cli-environment]
                             [current-output-port stdout]
                             [current-error-port stderr])
                (system*/exit-code racket-executable
                                   cli-main
                                   "manifest-compose"
                                   windows-manifest
                                   "--output"
                                   cli-output
                                   macos-manifest)))))))
    (check-equal? cli-status
                  0
                  (format "manifest-compose CLI failed; stdout: ~a; stderr: ~a"
                          (file->string cli-stdout-path)
                          (file->string cli-stderr-path)))
    (when (zero? cli-status)
      (check-true (file-exists? cli-output))
      (define-values (cli-composed _cli-payload cli-key-id _cli-signature)
        (call-with-input-file cli-output read-signed-manifest))
      (check-equal? cli-key-id "family-key")
      (check-equal? (length (update-manifest-artifacts cli-composed)) 3))

    ;; Disagreeing versions must be rejected loudly.
    (define deviant
      (build-path temp-root "update-deviant.json"))
    (write-manifest! deviant
                     (manifest #:version "1.5.0"
                               #:artifacts (list (artifact 'windows 'arm64 "https://updates.example/w-arm.msi"))))
    (check-exn #rx"disagree on version"
               (lambda ()
                 (compose-manifests! (list windows-manifest deviant)
                                     (build-path temp-root "bad.json")
                                     #:private-key private-key
                                     #:key-id "family-key")))

    ;; Duplicate platform+architecture legs are a release mistake.
    (check-exn #rx"same platform and architecture"
               (lambda ()
                 (compose-manifests!
                  (list windows-manifest windows-manifest)
                  (build-path temp-root "dup.json")
                  #:private-key private-key
                  #:key-id "family-key")))

    ;; A family signature must never endorse an unauthenticated release leg.
    (define wrong-key-id
      (build-path temp-root "update-wrong-key-id.json"))
    (write-manifest!
     wrong-key-id
     (manifest #:artifacts
               (list (artifact 'windows 'arm64
                               "https://updates.example/w-arm64.msi")))
     "other-key")
    (check-exn #rx"unexpected key"
               (lambda ()
                 (compose-manifests!
                  (list windows-manifest wrong-key-id)
                  (build-path temp-root "wrong-key-output.json")
                  #:private-key private-key
                  #:key-id "family-key")))

    (define tampered (build-path temp-root "update-tampered.json"))
    (define wrapper
      (call-with-input-file macos-manifest read-json))
    (call-with-output-file tampered
      #:exists 'truncate/replace
      (lambda (out)
        (write-json
         (hash-set wrapper
                   'signature
                   (hash-set (hash-ref wrapper 'signature)
                             'value
                             (bytes->base64-string (make-bytes 64 0))))
         out)))
    (check-exn #rx"signature verification failed"
               (lambda ()
                 (compose-manifests!
                  (list windows-manifest tampered)
                  (build-path temp-root "tampered-output.json")
                  #:private-key private-key
                  #:key-id "family-key"))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
