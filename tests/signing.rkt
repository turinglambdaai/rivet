#lang racket/base

(require rackunit
         racket/file
         "../rivet-cli/signing-options.rkt")

(define signing-vars
  '(#"RIVET_WINDOWS_SIGN_CERT_SHA1"
    #"RIVET_WINDOWS_SIGN_PFX"
    #"RIVET_WINDOWS_SIGN_PFX_PASSWORD"
    #"RIVET_WINDOWS_TIMESTAMP_URL"
    #"RIVET_MACOS_SIGN_IDENTITY"
    #"RIVET_MACOS_NOTARY_PROFILE"
    #"RIVET_LINUX_SIGN_PRIVATE_KEY"
    #"RIVET_LINUX_SIGN_KEY_ID"
    #"RIVET_LINUX_SIGN_PUBLIC_KEY"))

(define (with-signing-env entries thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([name (in-list signing-vars)])
    (environment-variables-set! env name #f))
  (for ([entry (in-list entries)])
    (environment-variables-set! env (car entry) (cdr entry)))
  (parameterize ([current-environment-variables env])
    (thunk)))

(check-exn
 #rx"requires RIVET_WINDOWS_SIGN_CERT_SHA1 or RIVET_WINDOWS_SIGN_PFX"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_WINDOWS_TIMESTAMP_URL" #"https://timestamp.example"))
    load-windows-production-signing)))

(check-exn
 #rx"exactly one Windows signing identity"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_WINDOWS_SIGN_CERT_SHA1" #"001122")
          (cons #"RIVET_WINDOWS_SIGN_PFX" #"certificate.pfx")
          (cons #"RIVET_WINDOWS_SIGN_PFX_PASSWORD" #"secret")
          (cons #"RIVET_WINDOWS_TIMESTAMP_URL" #"https://timestamp.example"))
    load-windows-production-signing)))

(check-exn
 #rx"RIVET_WINDOWS_SIGN_PFX_PASSWORD"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_WINDOWS_SIGN_PFX" #"certificate.pfx")
          (cons #"RIVET_WINDOWS_TIMESTAMP_URL" #"https://timestamp.example"))
    load-windows-production-signing)))

(check-exn
 #rx"RIVET_WINDOWS_TIMESTAMP_URL"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_WINDOWS_SIGN_CERT_SHA1" #"001122"))
    load-windows-production-signing)))

(let ([settings
       (with-signing-env
        (list (cons #"RIVET_WINDOWS_SIGN_CERT_SHA1" #"001122")
              (cons #"RIVET_WINDOWS_TIMESTAMP_URL" #"https://timestamp.example"))
        load-windows-production-signing)])
  (check-equal? (windows-signing-certificate-sha1 settings) "001122")
  (check-false (windows-signing-pfx settings))
  (check-equal? (windows-signing-timestamp-url settings)
                "https://timestamp.example"))

(let ([settings
       (with-signing-env
        (list (cons #"RIVET_WINDOWS_SIGN_PFX" #"certificate.pfx")
              ;; An empty PFX password is valid when explicitly configured.
              (cons #"RIVET_WINDOWS_SIGN_PFX_PASSWORD" #"")
              (cons #"RIVET_WINDOWS_TIMESTAMP_URL" #"https://timestamp.example"))
        load-windows-production-signing)])
  (check-equal? (windows-signing-pfx settings) "certificate.pfx")
  (check-equal? (windows-signing-pfx-password settings) ""))

(check-exn
 #rx"RIVET_MACOS_SIGN_IDENTITY"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_MACOS_NOTARY_PROFILE" #"rivet-notary"))
    load-macos-production-signing)))

(check-exn
 #rx"Developer ID signing identity"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_MACOS_SIGN_IDENTITY" #"-")
          (cons #"RIVET_MACOS_NOTARY_PROFILE" #"rivet-notary"))
    load-macos-production-signing)))

(check-exn
 #rx"RIVET_MACOS_NOTARY_PROFILE"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_MACOS_SIGN_IDENTITY" #"Developer ID Application: Example"))
    load-macos-production-signing)))

(let ([settings
       (with-signing-env
        (list (cons #"RIVET_MACOS_SIGN_IDENTITY"
                    #"Developer ID Application: Example")
              (cons #"RIVET_MACOS_NOTARY_PROFILE" #"rivet-notary"))
        load-macos-production-signing)])
  (check-equal? (macos-signing-identity settings)
                "Developer ID Application: Example")
  (check-equal? (macos-signing-notary-profile settings) "rivet-notary"))

(check-exn
 #rx"RIVET_LINUX_SIGN_PRIVATE_KEY"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_LINUX_SIGN_KEY_ID" #"release-2026"))
    load-linux-production-signing)))

(check-exn
 #rx"configured Linux signing key does not exist"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_LINUX_SIGN_PRIVATE_KEY"
                (string->bytes/utf-8
                 (path->string
                  (build-path (make-temporary-file "rivet-sign-~a" 'directory)
                              "missing.der"))))
          (cons #"RIVET_LINUX_SIGN_KEY_ID" #"release-2026"))
    load-linux-production-signing)))

(check-exn
 #rx"RIVET_LINUX_SIGN_KEY_ID"
 (lambda ()
   (define key (make-temporary-file "rivet-sign-key-~a.der"))
   (with-signing-env
    (list (cons #"RIVET_LINUX_SIGN_PRIVATE_KEY" (path->bytes key)))
    load-linux-production-signing)))

(let ([key (make-temporary-file "rivet-sign-key-~a.der")])
  (let ([settings
         (with-signing-env
          (list (cons #"RIVET_LINUX_SIGN_PRIVATE_KEY" (path->bytes key))
                (cons #"RIVET_LINUX_SIGN_KEY_ID" #"release-2026"))
          load-linux-production-signing)])
    (check-equal? (linux-signing-private-key settings) (path->string key))
    (check-equal? (linux-signing-key-id settings) "release-2026")))

(check-exn
 #rx"RIVET_LINUX_SIGN_PUBLIC_KEY"
 (lambda ()
   (with-signing-env '() load-linux-production-verification)))

(check-exn
 #rx"configured Linux verification key does not exist"
 (lambda ()
   (with-signing-env
    (list (cons #"RIVET_LINUX_SIGN_PUBLIC_KEY" #"missing-public.der"))
    load-linux-production-verification)))

(let ([public-key (make-temporary-file "rivet-sign-public-~a.der")])
  (check-equal?
   (with-signing-env
    (list (cons #"RIVET_LINUX_SIGN_PUBLIC_KEY" (path->bytes public-key)))
    load-linux-production-verification)
   (path->string public-key)))
