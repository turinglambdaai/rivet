#lang racket/base

(require rackunit
         "../rivet-cli/signing-options.rkt")

(define signing-vars
  '(#"RIVET_WINDOWS_SIGN_CERT_SHA1"
    #"RIVET_WINDOWS_SIGN_PFX"
    #"RIVET_WINDOWS_SIGN_PFX_PASSWORD"
    #"RIVET_WINDOWS_TIMESTAMP_URL"
    #"RIVET_MACOS_SIGN_IDENTITY"
    #"RIVET_MACOS_NOTARY_PROFILE"))

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
