#lang racket/base

(require json
         net/url
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
         execute-install-plan!
         recover-install-plan!)

(struct updater-config
  (application-id current-version channel platform architecture
                  public-key expected-key-id rollout-bucket maximum-download-bytes)
  #:transparent)

(struct update-candidate (manifest artifact) #:transparent)
(struct install-plan (candidate downloaded-path backup-path install restart rollback) #:transparent)

(define install-journal-schema 1)
(define install-journal-phases
  '(prepared installing installed restarting restarted checking healthy
             committing committed rollback-started rolled-back rollback-failed))

(define (wait-for-download-bytes! in buffer
                                  #:stall-seconds stall-seconds
                                  #:total-deadline total-deadline)
  ;; Blocks until at least one byte is available, the peer reaches EOF, the
  ;; stall deadline passes, or the total deadline fires. Returns the byte
  ;; count, eof, 'stall, or 'total respectively.
  (define ready
    (sync/timeout stall-seconds
                  (peek-bytes-avail!-evt (make-bytes 1) 0 in)
                  total-deadline))
  (cond
    [(not ready) 'stall]
    [(eq? ready total-deadline) 'total]
    [else (read-bytes-avail! buffer in)]))

(define (copy-limited! in out limit
                       #:who [who 'copy-limited!]
                       #:on-progress [on-progress void]
                       #:progress-every [progress-every 1]
                       #:stall-seconds [stall-seconds 60]
                       #:total-seconds [total-seconds #f])
  ;; Report the initial zero and the final byte count. Intermediate reports are
  ;; separated by at least progress-every bytes so fast links do not flood UI
  ;; pollers. This helper stays private; download-update is the public contract.
  ;; A stalled peer (no bytes for stall-seconds) and an optional total deadline
  ;; raise instead of parking the backend serve thread forever.
  (unless (and (real? stall-seconds) (> stall-seconds 0))
    (raise-argument-error who "positive real?" stall-seconds))
  (unless (or (not total-seconds) (and (real? total-seconds) (> total-seconds 0)))
    (raise-argument-error who "(or/c #f positive real?)" total-seconds))
  (define buffer (make-bytes 65536))
  (define total-deadline
    (and total-seconds
         (alarm-evt (+ (current-inexact-milliseconds) (* total-seconds 1000)))))
  (on-progress 0)
  (let loop ([total 0] [last-reported 0])
    (define count
      (wait-for-download-bytes! in buffer
                                #:stall-seconds stall-seconds
                                #:total-deadline
                                (or total-deadline never-evt)))
    (cond
      [(eq? count 'stall)
       (error who "download stalled: no bytes for ~a seconds" stall-seconds)]
      [(eq? count 'total)
       (error who "download exceeded its ~a second total deadline" total-seconds)]
      [(eof-object? count)
       (unless (= last-reported total) (on-progress total))
       total]
      [else
       (define next (+ total count))
       (when (> next limit)
         (error who "response exceeds permitted byte limit"))
       (write-bytes buffer out 0 count)
       (when (>= (- next last-reported) progress-every)
         (on-progress next)
         (set! last-reported next))
       (loop next last-reported)])))

(define (call-with-partial-cleanup temporary thunk)
  (with-handlers ([exn?
                   (lambda (error)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise error))])
    (thunk)))

(module+ test
  (provide copy-limited!
           call-with-partial-cleanup
           call-with-fetch-deadline))

;; GitHub release assets — the dominant update origin — answer with a 302
;; to their CDN, so every fetch must follow redirections or the updater
;; verifies an empty body and fails.
(define update-fetch-redirections 10)

(define update-fetch-connect-timeout-seconds 30)
(define update-fetch-idle-timeout-seconds 60)

;; get-pure-port blocks on the TCP connect with no interruptible event, so
;; the whole fetch runs in a custodian-owned worker and a deadline past
;; connect + idle shutdowns the worker and its socket instead of parking the
;; backend serve thread on a black-holed peer.
(define (call-with-fetch-deadline who connect-seconds idle-seconds thunk)
  (define custodian (make-custodian))
  (define result-channel (make-channel))
  (define worker
    (parameterize ([current-custodian custodian])
      (thread
       (lambda ()
         (with-handlers ([exn? (lambda (error) (channel-put result-channel error))])
           (channel-put result-channel (thunk)))))))
  (define outcome
    (sync/timeout (+ connect-seconds idle-seconds) result-channel))
  (cond
    [(not outcome)
     (custodian-shutdown-all custodian)
     (error who
            "update fetch exceeded its ~a second deadline"
            (+ connect-seconds idle-seconds))]
    [else
     (custodian-shutdown-all custodian)
     (if (exn? outcome) (raise outcome) outcome)]))

(define (fetch-update-manifest manifest-url public-key
                               #:key-id [key-id #f]
                               #:maximum-bytes [maximum-bytes (* 1024 1024)]
                               #:connect-timeout-seconds
                               [connect-timeout-seconds
                                update-fetch-connect-timeout-seconds]
                               #:idle-timeout-seconds
                               [idle-timeout-seconds
                                update-fetch-idle-timeout-seconds])
  (unless (and (string? manifest-url)
               (regexp-match? #px"^https://" manifest-url))
    (raise-argument-error 'fetch-update-manifest "HTTPS URL string" manifest-url))
  (unless (and (real? connect-timeout-seconds) (> connect-timeout-seconds 0))
    (raise-argument-error 'fetch-update-manifest "positive real?" connect-timeout-seconds))
  (unless (and (real? idle-timeout-seconds) (> idle-timeout-seconds 0))
    (raise-argument-error 'fetch-update-manifest "positive real?" idle-timeout-seconds))
  (call-with-fetch-deadline
   'fetch-update-manifest connect-timeout-seconds idle-timeout-seconds
   (lambda ()
     (define in (get-pure-port (string->url manifest-url)
                               '("User-Agent: Rivet-Updater/1")
                               #:redirections update-fetch-redirections))
     (dynamic-wind
       void
       (lambda ()
         (define out (open-output-bytes))
         (copy-limited! in out maximum-bytes
                        #:who 'fetch-update-manifest
                        #:stall-seconds idle-timeout-seconds)
         (verify-signed-manifest (open-input-bytes (get-output-bytes out))
                                 public-key
                                 #:key-id key-id))
       (lambda () (close-input-port in))))))

(define install-kinds '(portable msi appimage package-manager))

(define (artifact-matches-install-kind? artifact install-kind)
  (or (not install-kind)
      (case install-kind
        [(portable) (eq? (update-artifact-installer artifact) 'zip)]
        [(msi) (eq? (update-artifact-installer artifact) 'msi)]
        [(appimage) (eq? (update-artifact-installer artifact) 'appimage)]
        [(package-manager)
         (and (memq (update-artifact-installer artifact) '(deb rpm)) #t)])))

(define (select-update config manifest #:install-kind [install-kind #f])
  (unless (or (not install-kind) (memq install-kind install-kinds))
    (raise-argument-error 'select-update
                          "(or/c #f 'portable 'msi 'appimage 'package-manager)"
                          install-kind))
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
                                    (updater-config-architecture config))
                               (artifact-matches-install-kind? item install-kind)))
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

(define (download-update config candidate destination
                         #:on-progress [on-progress void]
                         #:progress-every [configured-progress-every #f]
                         #:stall-timeout-seconds [stall-timeout-seconds 60]
                         #:total-timeout-seconds [total-timeout-seconds #f])
  (unless (and (procedure? on-progress)
               (procedure-arity-includes? on-progress 1))
    (raise-argument-error 'download-update
                          "procedure accepting one argument"
                          on-progress))
  (unless (and (real? stall-timeout-seconds) (> stall-timeout-seconds 0))
    (raise-argument-error 'download-update
                          "positive real?"
                          stall-timeout-seconds))
  (unless (or (not total-timeout-seconds)
              (and (real? total-timeout-seconds) (> total-timeout-seconds 0)))
    (raise-argument-error 'download-update
                          "(or/c #f positive real?)"
                          total-timeout-seconds))
  (unless (or (not configured-progress-every)
              (exact-positive-integer? configured-progress-every))
    (raise-argument-error 'download-update
                          "(or/c #f exact-positive-integer?)"
                          configured-progress-every))
  (define artifact (update-candidate-artifact candidate))
  (define maximum (updater-config-maximum-download-bytes config))
  (when (> (update-artifact-size artifact) maximum)
    (error 'download-update "signed artifact size exceeds configured download limit"))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (call-with-partial-cleanup
   temporary
   (lambda ()
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
           (lambda (out)
             ;; Bound the stream to the signed size, not merely the looser
             ;; configured ceiling, so progress never exceeds 100% before a
             ;; malformed response is rejected.
             (copy-limited! in out (update-artifact-size artifact)
                            #:who 'download-update
                            #:on-progress on-progress
                            #:progress-every
                            (or configured-progress-every
                                (max 1
                                     (quotient
                                      (update-artifact-size artifact)
                                      100)))
                            #:stall-seconds stall-timeout-seconds
                            #:total-seconds total-timeout-seconds))))
       (lambda () (close-input-port in)))
     (verify-update-artifact! candidate temporary)
     (rename-file-or-directory temporary destination #t)
     destination)))

(define (make-install-plan candidate downloaded-path
                           #:backup-path [backup-path #f]
                           #:install install
                           #:restart [restart void]
                           #:rollback [rollback void])
  (install-plan candidate downloaded-path backup-path install restart rollback))

(define (normalized-path-string path)
  (path->string (simplify-path (path->complete-path path) #f)))

(define (install-journal-record plan phase)
  (define candidate (install-plan-candidate plan))
  (define manifest (update-candidate-manifest candidate))
  (define artifact (update-candidate-artifact candidate))
  (hasheq 'schema install-journal-schema
          'application_id (update-manifest-application-id manifest)
          'version (update-manifest-version manifest)
          'artifact_sha256 (update-artifact-sha256 artifact)
          'downloaded_path
          (normalized-path-string (install-plan-downloaded-path plan))
          'backup_path
          (and (install-plan-backup-path plan)
               (normalized-path-string (install-plan-backup-path plan)))
          'phase (symbol->string phase)))

(define (write-install-journal! path record)
  (make-parent-directory* path)
  (define temporary (path-add-extension path #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (call-with-output-file temporary
      #:exists 'truncate/replace
      (lambda (out)
        (write-json record out)
        (newline out)
        (flush-output out)))
    (rename-file-or-directory temporary path #t)))

(define (read-install-journal path)
  (unless (file-exists? path)
    (raise-arguments-error 'recover-install-plan!
                           "install transaction journal does not exist"
                           "journal" path))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (raise-arguments-error
                      'recover-install-plan!
                      "install transaction journal is malformed"
                      "journal" path
                      "detail" (exn-message e)))])
    (call-with-input-file path read-json)))

(define (journal-phase record)
  (define value (and (hash? record) (hash-ref record 'phase #f)))
  (define phase (and (string? value) (string->symbol value)))
  (and (memq phase install-journal-phases) phase))

(define (journal-matches-plan? record plan)
  (and (hash? record)
       (equal? (hash-ref record 'schema #f) install-journal-schema)
       (equal? record
               (install-journal-record plan (journal-phase record)))))

(define (delete-install-journal! path)
  (when (file-exists? path) (delete-file path)))

(define (record-install-phase! plan journal-path phase)
  (when journal-path
    (write-install-journal! journal-path
                            (install-journal-record plan phase))))

(define (rollback-allowed? plan)
  (update-manifest-rollback-allowed?
   (update-candidate-manifest (install-plan-candidate plan))))

(define (rollback-after-failure! plan journal-path original-error)
  (when (rollback-allowed? plan)
    (record-install-phase! plan journal-path 'rollback-started)
    (with-handlers
        ([exn:fail?
          (lambda (rollback-error)
            (record-install-phase! plan journal-path 'rollback-failed)
            (raise
             (exn:fail
              (format "~a; rollback also failed: ~a"
                      (exn-message original-error)
                      (exn-message rollback-error))
              (exn-continuation-marks original-error))))])
      ((install-plan-rollback plan)))
    (record-install-phase! plan journal-path 'rolled-back)
    (when journal-path (delete-install-journal! journal-path)))
  (raise original-error))

(define (execute-install-plan! plan
                               #:health-check [health-check (lambda () #t)]
                               #:commit [commit void]
                               #:journal-path [journal-path #f])
  ;; Platform adapters own elevation and process replacement. Rivet controls
  ;; the verified input, durable phase journal, health gate, and failure path,
  ;; keeping this state machine out of RVT1 and away from the embedded runtime
  ;; transport. A restart callback must return after starting the replacement;
  ;; the health check decides when that replacement is ready to commit.
  (record-install-phase! plan journal-path 'prepared)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (rollback-after-failure! plan journal-path e))])
    (record-install-phase! plan journal-path 'installing)
    ((install-plan-install plan) (install-plan-downloaded-path plan))
    (record-install-phase! plan journal-path 'installed)
    (record-install-phase! plan journal-path 'restarting)
    (define restart-result ((install-plan-restart plan)))
    (record-install-phase! plan journal-path 'restarted)
    (record-install-phase! plan journal-path 'checking)
    (unless (health-check)
      (error 'execute-install-plan! "installed update failed its health check"))
    (record-install-phase! plan journal-path 'healthy)
    (record-install-phase! plan journal-path 'committing)
    (commit)
    (record-install-phase! plan journal-path 'committed)
    (when journal-path (delete-install-journal! journal-path))
    restart-result))

(define (recover-install-plan! plan journal-path #:commit [commit void])
  ;; Recovery is deliberately conservative: a journal describes one exact
  ;; signed candidate and its paths. A different plan cannot consume it.
  ;; Rollback callbacks must be idempotent because a process may stop after the
  ;; rollback side effect but before the final phase is durably recorded.
  (define record (read-install-journal journal-path))
  (define phase (journal-phase record))
  (unless (and phase (journal-matches-plan? record plan))
    (raise-arguments-error 'recover-install-plan!
                           "install transaction journal does not match the plan"
                           "journal" journal-path))
  (case phase
    [(healthy committing)
     ;; The health gate passed before either phase was written. Commit must be
     ;; idempotent because recovery may repeat it after the side effect but
     ;; before the final phase reaches disk.
     (record-install-phase! plan journal-path 'committing)
     (commit)
     (record-install-phase! plan journal-path 'committed)
     (delete-install-journal! journal-path)
     'committed]
    [(committed)
     (delete-install-journal! journal-path)
     'committed]
    [(rolled-back)
     (delete-install-journal! journal-path)
     'rolled-back]
    [else
     (unless (rollback-allowed? plan)
       (raise-arguments-error
        'recover-install-plan!
        "interrupted install cannot be rolled back by signed policy"
        "phase" phase
        "journal" journal-path))
     (record-install-phase! plan journal-path 'rollback-started)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (record-install-phase! plan journal-path 'rollback-failed)
                        (raise e))])
       ((install-plan-rollback plan)))
     (record-install-phase! plan journal-path 'rolled-back)
     (delete-install-journal! journal-path)
     'rolled-back]))
