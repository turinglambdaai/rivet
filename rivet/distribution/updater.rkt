#lang racket/base

(require net/url
         racket/file
         racket/match
         racket/path
         racket/port
         racket/string
         "crypto.rkt"
         "manifest.rkt"
         "version.rkt")

(provide (struct-out updater-config)
         (struct-out update-candidate)
         (struct-out install-plan)
         fetch-update-manifest
         select-update
         download-update
         verify-update-artifact!
         make-install-plan
         execute-install-plan!)

(struct updater-config
  (application-id current-version channel platform architecture
                  public-key expected-key-id rollout-bucket maximum-download-bytes)
  #:transparent)

(struct update-candidate (manifest artifact) #:transparent)
(struct install-plan (candidate downloaded-path backup-path install restart rollback) #:transparent)

(define (copy-limited! in out limit)
  (define buffer (make-bytes 65536))
  (let loop ([total 0])
    (define count (read-bytes-avail! buffer in))
    (cond
      [(eof-object? count) total]
      [else
       (define next (+ total count))
       (when (> next limit)
         (error 'download-update "update exceeds configured download limit"))
       (write-bytes buffer out 0 count)
       (loop next)])))

;; GitHub release assets — the dominant update origin — answer with a 302
;; to their CDN, so every fetch must follow redirections or the updater
;; verifies an empty body and fails.
(define update-fetch-redirections 10)

(define (fetch-update-manifest manifest-url public-key
                               #:key-id [key-id #f]
                               #:maximum-bytes [maximum-bytes (* 1024 1024)])
  (unless (and (string? manifest-url)
               (regexp-match? #px"^https://" manifest-url))
    (raise-argument-error 'fetch-update-manifest "HTTPS URL string" manifest-url))
  (define in (get-pure-port (string->url manifest-url)
                            '("User-Agent: Rivet-Updater/1")
                            #:redirections update-fetch-redirections))
  (dynamic-wind
    void
    (lambda ()
      (define out (open-output-bytes))
      (copy-limited! in out maximum-bytes)
      (verify-signed-manifest (open-input-bytes (get-output-bytes out))
                              public-key
                              #:key-id key-id))
    (lambda () (close-input-port in))))

(define (select-update config manifest)
  (cond
    [(not (string=? (updater-config-application-id config)
                    (update-manifest-application-id manifest)))
     (error 'select-update "update manifest application identity mismatch")]
    [(not (eq? (updater-config-channel config)
               (update-manifest-channel manifest))) #f]
    [(not (version>? (update-manifest-version manifest)
                     (updater-config-current-version config))) #f]
    [(version<? (updater-config-current-version config)
                (update-manifest-minimum-version manifest)) #f]
    [(>= (updater-config-rollout-bucket config)
         (update-manifest-rollout manifest)) #f]
    [else
     (define artifact
       (for/first ([item (in-list (update-manifest-artifacts manifest))]
                   #:when (and (eq? (update-artifact-platform item)
                                    (updater-config-platform config))
                               (eq? (update-artifact-architecture item)
                                    (updater-config-architecture config))))
         item))
     (and artifact (update-candidate manifest artifact))]))

(define (verify-update-artifact! candidate path)
  (define artifact (update-candidate-artifact candidate))
  (unless (= (file-size path) (update-artifact-size artifact))
    (raise-arguments-error 'verify-update-artifact!
                           "download size does not match signed manifest"
                           "expected" (update-artifact-size artifact)
                           "actual" (file-size path)))
  (define actual (string-downcase (sha256-file/hex path)))
  (unless (string=? actual (update-artifact-sha256 artifact))
    (raise-arguments-error 'verify-update-artifact!
                           "download SHA-256 does not match signed manifest"
                           "expected" (update-artifact-sha256 artifact)
                           "actual" actual))
  path)

(define (download-update config candidate destination)
  (define artifact (update-candidate-artifact candidate))
  (define maximum (updater-config-maximum-download-bytes config))
  (when (> (update-artifact-size artifact) maximum)
    (error 'download-update "signed artifact size exceeds configured download limit"))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (define in
      (get-pure-port (string->url (update-artifact-url artifact))
                     '("User-Agent: Rivet-Updater/1")
                     #:redirections update-fetch-redirections))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out) (copy-limited! in out maximum))))
      (lambda () (close-input-port in)))
    (verify-update-artifact! candidate temporary)
    (rename-file-or-directory temporary destination #t)
    destination))

(define (make-install-plan candidate downloaded-path
                           #:backup-path [backup-path #f]
                           #:install install
                           #:restart [restart void]
                           #:rollback [rollback void])
  (install-plan candidate downloaded-path backup-path install restart rollback))

(define (execute-install-plan! plan)
  ;; Platform adapters own elevation and process replacement. Rivet controls
  ;; the verified input and the failure path, keeping this state machine out of
  ;; RVT1 and away from the embedded runtime transport.
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (update-manifest-rollback-allowed?
                            (update-candidate-manifest
                             (install-plan-candidate plan)))
                       ((install-plan-rollback plan)))
                     (raise e))])
    ((install-plan-install plan) (install-plan-downloaded-path plan))
    ((install-plan-restart plan))))
