#lang racket/base

(require racket/date
         file/zip
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

(provide release-project!
         release-update-environment
         portable-zip-path
         create-portable-zip!)

(define (required-environment name)
  (define value (getenv name))
  (unless (and value (not (string=? (string-trim value) "")))
    (error 'release-project! "required environment variable ~a is not set" name))
  (string-trim value))

(struct update-environment (base-url private-key key-id) #:transparent)

(define (release-update-environment updates?)
  (and updates?
       (update-environment
        (required-environment "RIVET_UPDATE_BASE_URL")
        (string->path (required-environment "RIVET_UPDATE_PRIVATE_KEY"))
        (required-environment "RIVET_UPDATE_KEY_ID"))))

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

(define (portable-zip-path project)
  (project-path
   project "dist"
   (format "~a-~a-~a-~a.zip"
           (project-name project)
           (project-version project)
           (release-platform)
           (release-architecture))))

;; Portable zip beside the installer: the family update feed consumes
;; it and it runs on locked-down machines. Deterministic input tree,
;; family naming <name>-<version>-<os>-<arch>.zip, sha256 alongside.
(define (create-portable-zip! project package)
  (define zip-path (portable-zip-path project))
  (when (file-exists? zip-path) (delete-file zip-path))
  (parameterize ([current-directory (path-only package)])
    (zip zip-path (path->string (file-name-from-path package))))
  (call-with-output-file (string-append (path->string zip-path) ".sha256")
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "~a  ~a~n"
              (sha256-file/hex zip-path)
              (path->string (file-name-from-path zip-path)))))
  zip-path)

(define (portable-update-artifact update-config portable-zip)
  (update-artifact
   (release-platform)
   (release-architecture)
   (string-append
    (string-trim (update-environment-base-url update-config) "/")
    "/"
    (path->string (file-name-from-path portable-zip)))
   (sha256-file/hex portable-zip)
   (file-size portable-zip)
   'zip
   '()))

(define (release-project! project
                          #:production? [production? #t]
                          #:updates? [updates? #t])
  ;; Linux production trust lives in the signed installer rather than
  ;; OS-level code signing, so the package itself is verified at development
  ;; strength and the released installer is production-verified below.
  (define linux-release? (eq? (system-type 'os) 'unix))
  (define package
    (package-project! project
                      #:production? (and production? (not linux-release?))))
  (define installer (create-installer! project package #:production? production?))
  ;; The portable zip rides beside every installer: the family update feed
  ;; consumes it, and it is the artifact users on locked-down machines can
  ;; still run. Same family naming as the installer, sha256 next to it.
  (define portable-zip (create-portable-zip! project package))
  (when (and production? linux-release?)
    ;; package-project! already performed the launch smoke. This second pass
    ;; adds Linux installer trust verification without opening the app twice.
    (verify-package! project package
                     #:production? #t
                     #:launch-smoke? #f))
  (define-values (sbom notices) (generate-compliance-artifacts! project))
  (define update-config (release-update-environment updates?))
  (define manifest-path
    (and
     update-config
     (let* ([previous (getenv "RIVET_PREVIOUS_VERSION")]
            [artifact
             (portable-update-artifact update-config portable-zip)]
            [manifest
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
              (list artifact))]
            [path
             (project-path
              project "dist"
              (format "update-~a.json" (project-release-channel project)))])
       (call-with-output-file path
         #:exists 'truncate/replace
         (lambda (out)
           (write-signed-manifest
            manifest
            (read-ed25519-private-key
             (update-environment-private-key update-config))
            (update-environment-key-id update-config)
            out)))
       path)))
  (values installer manifest-path sbom notices portable-zip))

(module+ test-support
  (provide portable-update-artifact))
