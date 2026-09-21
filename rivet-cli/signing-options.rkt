#lang racket/base

(require racket/string)

(provide (struct-out windows-signing)
         (struct-out macos-signing)
         load-windows-production-signing
         load-macos-production-signing)

(struct windows-signing (certificate-sha1 pfx pfx-password timestamp-url)
  #:transparent)
(struct macos-signing (identity notary-profile)
  #:transparent)

(define (non-empty-env name)
  (define value (getenv name))
  (and value
       (let ([trimmed (string-trim value)])
         (and (not (string=? trimmed "")) trimmed))))

(define (load-windows-production-signing)
  (define certificate-sha1 (non-empty-env "RIVET_WINDOWS_SIGN_CERT_SHA1"))
  (define pfx (non-empty-env "RIVET_WINDOWS_SIGN_PFX"))
  (define pfx-password (getenv "RIVET_WINDOWS_SIGN_PFX_PASSWORD"))
  (define timestamp-url (non-empty-env "RIVET_WINDOWS_TIMESTAMP_URL"))

  (when (and certificate-sha1 pfx)
    (error 'load-windows-production-signing
           "configure exactly one Windows signing identity: RIVET_WINDOWS_SIGN_CERT_SHA1 or RIVET_WINDOWS_SIGN_PFX, not both"))
  (unless (or certificate-sha1 pfx)
    (error 'load-windows-production-signing
           "production Windows packaging requires RIVET_WINDOWS_SIGN_CERT_SHA1 or RIVET_WINDOWS_SIGN_PFX"))
  (when (and pfx (not pfx-password))
    (error 'load-windows-production-signing
           "RIVET_WINDOWS_SIGN_PFX_PASSWORD must be set when RIVET_WINDOWS_SIGN_PFX is used"))
  (unless timestamp-url
    (error 'load-windows-production-signing
           "production Windows packaging requires RIVET_WINDOWS_TIMESTAMP_URL"))

  (windows-signing certificate-sha1 pfx pfx-password timestamp-url))

(define (load-macos-production-signing)
  (define identity (non-empty-env "RIVET_MACOS_SIGN_IDENTITY"))
  (define notary-profile (non-empty-env "RIVET_MACOS_NOTARY_PROFILE"))

  (unless identity
    (error 'load-macos-production-signing
           "production macOS packaging requires RIVET_MACOS_SIGN_IDENTITY"))
  (when (string=? identity "-")
    (error 'load-macos-production-signing
           "RIVET_MACOS_SIGN_IDENTITY must be a Developer ID signing identity, not ad-hoc '-'"))
  (unless notary-profile
    (error 'load-macos-production-signing
           "production macOS packaging requires RIVET_MACOS_NOTARY_PROFILE"))

  (macos-signing identity notary-profile))
