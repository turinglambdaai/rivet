#lang racket/base

(require rackunit
         racket/file
         racket/path
         crypto
         crypto/all
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/manifest.rkt"
         "../rivet-cli/manifest-compose.rkt")

(use-all-factories!)

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

(define (write-manifest! path m)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (write-signed-manifest m private-key "family-key" out))))

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
                  #:key-id "family-key"))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
