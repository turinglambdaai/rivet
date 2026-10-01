#lang racket/base

(require racket/date
         racket/file
         racket/format
         racket/path
         racket/string
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/manifest.rkt"
         "compliance.rkt"
         "installer.rkt"
         "package.rkt"
         "project.rkt"
         "verify.rkt")

(provide release-project!)

(define (required-environment name)
  (define value (getenv name))
  (unless (and value (not (string=? (string-trim value) "")))
    (error 'release-project! "required environment variable ~a is not set" name))
  (string-trim value))

(define (rfc3339-now)
  (define d (seconds->date (current-seconds) #t))
  (format "~a-~a-~aT~a:~a:~aZ"
          (~r (date-year d) #:min-width 4 #:pad-string "0")
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")))

(define (release-platform)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]))

(define (release-architecture)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

(define (installer-kind)
  (case (system-type 'os)
    [(windows) 'msi]
    [(macosx) 'dmg]
    [(unix) 'targz]))

(define (release-project! project #:production? [production? #t])
  ;; Linux production trust lives in the signed installer rather than
  ;; OS-level code signing, so the package itself is verified at development
  ;; strength and the released installer is production-verified below.
  (define linux-release? (eq? (system-type 'os) 'unix))
  (define package
    (package-project! project
                      #:production? (and production? (not linux-release?))))
  (define installer (create-installer! project package #:production? production?))
  (when (and production? linux-release?)
    ;; package-project! already performed the launch smoke. This second pass
    ;; adds Linux installer trust verification without opening the app twice.
    (verify-package! project package
                     #:production? #t
                     #:launch-smoke? #f))
  (define-values (sbom notices) (generate-compliance-artifacts! project))
  (define base-url (required-environment "RIVET_UPDATE_BASE_URL"))
  (define key-path (string->path (required-environment "RIVET_UPDATE_PRIVATE_KEY")))
  (define key-id (required-environment "RIVET_UPDATE_KEY_ID"))
  (define previous (getenv "RIVET_PREVIOUS_VERSION"))
  (define artifact
    (update-artifact
     (release-platform)
     (release-architecture)
     (string-append (string-trim base-url "/") "/"
                    (path->string (file-name-from-path installer)))
     (sha256-file/hex installer)
     (file-size installer)
     (installer-kind)
     '()))
  (define manifest
    (update-manifest
     (project-identifier project)
     (project-version project)
     (project-build project)
     (project-release-channel project)
     (rfc3339-now)
     (or (getenv "RIVET_MINIMUM_UPDATABLE_VERSION") "0.0.0")
     (and previous (not (string=? previous "")) previous)
     #t
     (let ([configured (getenv "RIVET_UPDATE_ROLLOUT")])
       (if configured (string->number configured) 100))
     (list artifact)))
  (define manifest-path
    (project-path project "dist"
                  (format "update-~a.json" (project-release-channel project))))
  (call-with-output-file manifest-path
    #:exists 'truncate/replace
    (lambda (out)
      (write-signed-manifest manifest
                             (read-ed25519-private-key key-path)
                             key-id out)))
  (values installer manifest-path sbom notices))
