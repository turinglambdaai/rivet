#lang racket/base

;; One bounded check/download state machine for native applications. The
;; platform host still owns installation and restart; this module owns the
;; authenticated network work and its observable lifecycle.

(require racket/async-channel
         racket/file
         racket/match
         racket/path
         racket/string
         "crypto.rkt"
         "manifest.rkt"
         "platform-adapter.rkt"
         "updater.rkt"
         "version.rkt")

(provide updater?
         make-updater
         updater-state
         updater-check!
         updater-download!
         updater-cancel!
         updater-wait
         current-update-architecture)

(struct updater
  (application-id current-version channel platform architecture install-kind
                  public-key resolved-key key-id manifest-url data-directory
                  rollout-bucket maximum-manifest-bytes maximum-download-bytes
                  check-timeout stall-timeout total-timeout
                  fetch-manifest download
                  lock snapshot candidate operation worker cancel-reason)
  #:mutable)

(define current-managed-fetch-manifest (make-parameter fetch-update-manifest))
(define current-managed-download (make-parameter download-update))

(define (update-architecture-for machine)
  (case machine
    [(x86_64 amd64) 'x64]
    [(aarch64 arm64) 'arm64]
    [else
     (raise-arguments-error 'current-update-architecture
                            "unsupported update architecture"
                            "architecture" machine)]))

(define (current-update-architecture)
  (update-architecture-for (system-type 'arch)))

(define (positive-real? value)
  (and (real? value) (positive? value)))

(define (safe-component value)
  (define cleaned (regexp-replace* #px"[^A-Za-z0-9._-]+" value "_"))
  (if (string=? cleaned "") "application" cleaned))

(define (immutable-json-value value)
  (cond
    [(hash? value)
     (for/hasheq ([(key item) (in-hash value)])
       (values key (immutable-json-value item)))]
    [(list? value) (map immutable-json-value value)]
    [(string? value) (string->immutable-string value)]
    [else value]))

(define (default-destination application-id data-directory candidate)
  (define manifest (update-candidate-manifest candidate))
  (define artifact (update-candidate-artifact candidate))
  (build-path
   data-directory
   "updates"
   (format "~a-~a-~a-~a.~a"
           (safe-component application-id)
           (update-manifest-version manifest)
           (update-artifact-platform artifact)
           (update-artifact-architecture artifact)
           (update-artifact-installer artifact))))

(define (initial-state current-version)
  (hasheq 'phase "idle"
          'percent 0
          'message #f
          'downloadedPath #f
          'availableVersion #f
          'currentVersion (string->immutable-string current-version)))

(define (make-updater #:application-id application-id
                      #:current-version current-version
                      #:channel [channel 'stable]
                      #:platform [platform (current-update-platform)]
                      #:architecture [architecture (current-update-architecture)]
                      #:install-kind [install-kind #f]
                      #:public-key public-key
                      #:key-id key-id
                      #:manifest-url manifest-url
                      #:data-directory data-directory
                      #:rollout-bucket rollout-bucket
                      #:maximum-manifest-bytes
                      [maximum-manifest-bytes (* 1024 1024)]
                      #:maximum-download-bytes
                      [maximum-download-bytes (* 512 1024 1024)]
                      #:check-timeout [check-timeout 30.0]
                      #:stall-timeout [stall-timeout 120.0]
                      #:total-timeout [total-timeout (* 30.0 60.0)])
  (unless (and (string? application-id) (not (string=? application-id "")))
    (raise-argument-error 'make-updater "non-empty string?" application-id))
  (unless (version? current-version)
    (raise-argument-error 'make-updater "version?" current-version))
  (unless (valid-channel? channel)
    (raise-argument-error 'make-updater "valid-channel?" channel))
  (unless (memq platform '(windows macos linux))
    (raise-argument-error
     'make-updater "(or/c 'windows 'macos 'linux)" platform))
  (unless (memq architecture '(x64 arm64))
    (raise-argument-error
     'make-updater "(or/c 'x64 'arm64)" architecture))
  (unless (or (not install-kind)
              (memq install-kind '(portable msi appimage package-manager)))
    (raise-argument-error
     'make-updater
     "(or/c #f 'portable 'msi 'appimage 'package-manager)"
     install-kind))
  (unless (and (string? key-id) (not (string=? key-id "")))
    (raise-argument-error 'make-updater "non-empty string?" key-id))
  (unless (and (string? manifest-url)
               (regexp-match? #px"^https://" manifest-url))
    (raise-argument-error 'make-updater "HTTPS URL string" manifest-url))
  (unless (and (exact-integer? rollout-bucket) (<= 0 rollout-bucket 99))
    (raise-argument-error 'make-updater "integer from 0 through 99"
                          rollout-bucket))
  (for ([value (in-list (list maximum-manifest-bytes maximum-download-bytes))]
        [name (in-list '(maximum-manifest-bytes maximum-download-bytes))])
    (unless (exact-positive-integer? value)
      (raise-argument-error 'make-updater
                            (format "exact-positive-integer? for ~a" name)
                            value)))
  (for ([value (in-list (list check-timeout stall-timeout total-timeout))]
        [name (in-list '(check-timeout stall-timeout total-timeout))])
    (unless (positive-real? value)
      (raise-argument-error 'make-updater
                            (format "positive real? for ~a" name)
                            value)))
  (updater (string->immutable-string application-id)
           (string->immutable-string current-version)
           channel platform architecture
           install-kind
           (if (bytes? public-key)
               (bytes->immutable-bytes public-key)
               public-key)
           #f
           (string->immutable-string key-id)
           (string->immutable-string manifest-url)
           (path->complete-path data-directory) rollout-bucket
           maximum-manifest-bytes maximum-download-bytes check-timeout
           stall-timeout total-timeout
           (current-managed-fetch-manifest) (current-managed-download)
           (make-semaphore 1) (initial-state current-version) #f #f #f #f))

(define (with-updater-lock instance thunk)
  (call-with-semaphore (updater-lock instance) thunk))

(define (state-set*/locked! instance . fields)
  (set-updater-snapshot!
   instance
   (apply hash-set*
          (updater-snapshot instance)
          (for/list ([field (in-list fields)] [index (in-naturals)])
            (if (odd? index) (immutable-json-value field) field)))))

(define (updater-state instance)
  (unless (updater? instance)
    (raise-argument-error 'updater-state "updater?" instance))
  (with-updater-lock instance (lambda () (updater-snapshot instance))))

(define (resolved-public-key instance)
  (or (updater-resolved-key instance)
      (let ([key (if (bytes? (updater-public-key instance))
                     (bytes->ed25519-public-key (updater-public-key instance))
                     (updater-public-key instance))])
        (set-updater-resolved-key! instance key)
        key)))

(define (call-with-timeout who seconds thunk)
  (define result (make-async-channel))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([exn? (lambda (error)
                               (async-channel-put result (cons 'error error)))])
         (async-channel-put result (cons 'value (thunk)))))))
  (define (stop-worker!)
    ;; The caller may itself be handling an asynchronous break. Disable
    ;; further breaks until the owned child is gone so cancellation cannot
    ;; strand a manifest request in the background.
    (parameterize-break #f
      (when (thread-running? worker)
        (break-thread worker))
      (sync (thread-dead-evt worker))))
  (define outcome
    (with-handlers ([exn? (lambda (error)
                            (stop-worker!)
                            (raise error))])
      (sync/timeout seconds result)))
  (cond
    [outcome
     (match outcome
       [(cons 'value value) value]
       [(cons 'error error) (raise error)])]
    [else
     (stop-worker!)
     (error who "operation exceeded its ~a-second deadline" seconds)]))

(define (updater-config-for instance key)
  (updater-config (updater-application-id instance)
                  (updater-current-version instance)
                  (updater-channel instance)
                  (updater-platform instance)
                  (updater-architecture instance)
                  key
                  (updater-key-id instance)
                  (updater-rollout-bucket instance)
                  (updater-maximum-download-bytes instance)))

(define (available-result instance candidate)
  (define manifest (update-candidate-manifest candidate))
  (define artifact (update-candidate-artifact candidate))
  (immutable-json-value
   (hasheq 'status "available"
           'currentVersion (updater-current-version instance)
           'availableVersion (update-manifest-version manifest)
           'build (update-manifest-build manifest)
           'publishedAt (update-manifest-published-at manifest)
           'installer (symbol->string (update-artifact-installer artifact))
           'sizeBytes (update-artifact-size artifact))))

(define (record-check-error! instance error)
  (with-updater-lock
   instance
   (lambda ()
     (set-updater-operation! instance #f)
     (state-set*/locked! instance
                         'phase "error"
                         'message (exn-message error)))))

(define (updater-check! instance)
  (unless (updater? instance)
    (raise-argument-error 'updater-check! "updater?" instance))
  (with-updater-lock
   instance
   (lambda ()
     (when (updater-operation instance)
       (error 'updater-check! "another updater operation is already running"))
     (set-updater-operation! instance 'check)
     (set-updater-candidate! instance #f)
     (set-updater-snapshot!
      instance
      (hash-set* (initial-state (updater-current-version instance))
                 'phase "checking"))))
  (with-handlers
      ([exn:break?
        (lambda (error)
          (record-check-error! instance error)
          (raise error))]
       [exn:fail?
        (lambda (error)
          (record-check-error! instance error)
          (immutable-json-value
           (hasheq 'status "error" 'message (exn-message error))))])
    (define key (resolved-public-key instance))
    (define manifest
      (call-with-timeout
       'updater-check!
       (updater-check-timeout instance)
       (lambda ()
         ((updater-fetch-manifest instance)
          (updater-manifest-url instance)
          key
          #:key-id (updater-key-id instance)
          #:maximum-bytes (updater-maximum-manifest-bytes instance)))))
    (define config (updater-config-for instance key))
    (define candidate
      (select-update config manifest
                     #:install-kind (updater-install-kind instance)))
    (define result
      (if candidate
          (available-result instance candidate)
          (immutable-json-value
           (hasheq 'status "up-to-date"
                   'currentVersion (updater-current-version instance)))))
    (with-updater-lock
     instance
     (lambda ()
       (set-updater-operation! instance #f)
       (set-updater-candidate! instance candidate)
       (state-set*/locked!
        instance
        'phase (if candidate "available" "up-to-date")
        'message #f
        'availableVersion
        (and candidate
             (update-manifest-version
              (update-candidate-manifest candidate))))))
    result))

(define (candidate-destination instance candidate)
  (path->complete-path
   (default-destination (updater-application-id instance)
                        (updater-data-directory instance)
                        candidate)))

(define (publish-download-failure! instance worker error)
  (with-updater-lock
   instance
   (lambda ()
     (when (eq? worker (updater-worker instance))
       (define reason (updater-cancel-reason instance))
       (set-updater-worker! instance #f)
       (set-updater-operation! instance #f)
       (set-updater-cancel-reason! instance #f)
       (state-set*/locked!
        instance
        'phase (if (eq? reason 'cancelled) "cancelled" "error")
        'message
        (case reason
          [(cancelled) "update download cancelled"]
          [(stalled) "update download stalled"]
          [(timed-out) "update download timed out"]
          [else (exn-message error)]))))))

(define (start-watchdog! instance worker started last-activity)
  (define interval
    (max 0.01 (min 1.0 (/ (updater-stall-timeout instance) 2.0))))
  (thread
   (lambda ()
     (let loop ()
       (unless (sync/timeout interval (thread-dead-evt worker))
         (define now (current-inexact-monotonic-milliseconds))
         (define stalled?
           (> (- now (unbox last-activity))
              (* 1000.0 (updater-stall-timeout instance))))
         (define timed-out?
           (> (- now started)
              (* 1000.0 (updater-total-timeout instance))))
         (cond
           [(or stalled? timed-out?)
            (with-updater-lock
             instance
             (lambda ()
               (when (eq? worker (updater-worker instance))
                 (unless (updater-cancel-reason instance)
                   (set-updater-cancel-reason!
                    instance
                    (if stalled? 'stalled 'timed-out))))))
            (break-thread worker)]
           [else (loop)]))))))

(define (updater-download! instance)
  (unless (updater? instance)
    (raise-argument-error 'updater-download! "updater?" instance))
  (define gate (make-semaphore 0))
  (define-values (last-activity worker)
    (with-updater-lock
     instance
     (lambda ()
       (when (updater-operation instance)
         (error 'updater-download! "another updater operation is already running"))
       (define candidate (updater-candidate instance))
       (unless candidate
         (error 'updater-download! "no update is available; run updater-check! first"))
       (define key (resolved-public-key instance))
       (define config (updater-config-for instance key))
       (define destination (candidate-destination instance candidate))
       (define total
         (update-artifact-size (update-candidate-artifact candidate)))
       (define last-activity
         (box (current-inexact-monotonic-milliseconds)))
       (define worker #f)
       (set! worker
             (thread
              (lambda ()
                (semaphore-wait gate)
                (with-handlers
                    ([exn?
                      (lambda (error)
                        (publish-download-failure! instance worker error))])
                  (define path
                    ((updater-download instance)
                     config candidate destination
                     #:on-progress
                     (lambda (downloaded)
                       (set-box! last-activity
                                 (current-inexact-monotonic-milliseconds))
                       (define percent
                         (if (zero? total)
                             0
                             (min 100 (quotient (* downloaded 100) total))))
                       (with-updater-lock
                        instance
                        (lambda ()
                          (when (eq? worker (updater-worker instance))
                            (state-set*/locked! instance 'percent percent)))))
                     #:progress-every 1))
                  (with-updater-lock
                   instance
                   (lambda ()
                     (when (eq? worker (updater-worker instance))
                       (set-updater-worker! instance #f)
                       (set-updater-operation! instance #f)
                       (set-updater-cancel-reason! instance #f)
                       (state-set*/locked!
                        instance
                        'phase "downloaded"
                        'percent 100
                        'message #f
                        'downloadedPath (path->string path)))))))))
       (set-updater-operation! instance 'download)
       (set-updater-worker! instance worker)
       (set-updater-cancel-reason! instance #f)
       (state-set*/locked! instance
                           'phase "downloading"
                           'percent 0
                           'message #f
                           'downloadedPath #f)
       (values last-activity worker))))
  (define started (current-inexact-monotonic-milliseconds))
  (semaphore-post gate)
  (start-watchdog! instance worker started last-activity)
  (void))

(define (updater-cancel! instance)
  (unless (updater? instance)
    (raise-argument-error 'updater-cancel! "updater?" instance))
  (define worker
    (with-updater-lock
     instance
     (lambda ()
       (define worker (updater-worker instance))
       (and worker
            (thread-running? worker)
            (begin
              (set-updater-cancel-reason! instance 'cancelled)
              worker)))))
  (and worker (begin (break-thread worker) #t)))

(define (updater-wait instance [timeout #f])
  (unless (updater? instance)
    (raise-argument-error 'updater-wait "updater?" instance))
  (unless (or (not timeout) (and (real? timeout) (not (negative? timeout))))
    (raise-argument-error 'updater-wait "(or/c #f nonnegative-real?)" timeout))
  (define worker
    (with-updater-lock instance (lambda () (updater-worker instance))))
  (cond
    [(not worker) (updater-state instance)]
    [(if timeout
         (sync/timeout timeout (thread-dead-evt worker))
         (sync (thread-dead-evt worker)))
     (updater-state instance)]
    [else #f]))

(module+ test-support
  (provide current-managed-fetch-manifest
           current-managed-download
           default-destination
           update-architecture-for))
