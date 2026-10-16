#lang racket/base

(require rackunit
         racket/file
         "../../rivet/distribution.rkt"
         (submod "../../rivet/distribution/managed-updater.rkt" test-support))

(define artifact
  (update-artifact 'windows 'x64 "https://updates.example/app.zip"
                   (make-string 64 #\a) 100 'zip '() #f))
(define manifest
  (update-manifest "dev.rivet.managed-test" "2.0.0" 2 'stable
                   "2026-10-13T00:00:00Z" "0.0.0" "1.0.0"
                   #t 100 (list artifact)))

(check-eq? (update-architecture-for 'x86_64) 'x64)
(check-eq? (update-architecture-for 'amd64) 'x64)
(check-eq? (update-architecture-for 'aarch64) 'arm64)
(check-exn #rx"unsupported update architecture"
           (lambda () (update-architecture-for 'riscv64)))

(define (fake-fetch _url _key
                    #:key-id [_key-id #f]
                    #:maximum-bytes [_maximum-bytes (* 1024 1024)])
  manifest)

(define (make-test-updater root download
                           #:current-version [current-version "1.0.0"]
                           #:check-timeout [check-timeout 1.0]
                           #:stall-timeout [stall-timeout 1.0]
                           #:total-timeout [total-timeout 2.0]
                           #:fetch [fetch fake-fetch]
                           #:silent-throttle-seconds [silent-throttle-seconds
                                                      (* 4 60 60)]
                           #:settings-get [settings-get #f]
                           #:settings-set! [settings-set! #f])
  (parameterize ([current-managed-fetch-manifest fetch]
                 [current-managed-download download])
    (make-updater
     #:application-id "dev.rivet.managed-test"
     #:current-version current-version
     #:platform 'windows
     #:architecture 'x64
     #:install-kind 'portable
     #:public-key 'test-key
     #:key-id "test-2026"
     #:manifest-url "https://updates.example/update-stable.json"
     #:data-directory root
     #:rollout-bucket 17
     #:check-timeout check-timeout
     #:stall-timeout stall-timeout
     #:total-timeout total-timeout
     #:silent-throttle-seconds silent-throttle-seconds
     #:settings-get settings-get
     #:settings-set! settings-set!)))

;; A plain in-memory settings store behind the managed interface: string
;; keys, arbitrary values, durable-enough semantics for tests.
(define (make-settings-store)
  (define table (make-hash))
  (values
   (lambda (key) (hash-ref table key #f))
   (lambda (key value) (hash-set! table key value))
   table))

(define root (make-temporary-file "rivet-managed-updater-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define (successful-download _config _candidate destination
                                 #:on-progress on-progress
                                 #:progress-every progress-every)
      (check-equal? progress-every 1)
      (for ([downloaded (in-list '(0 50 100))])
        (on-progress downloaded))
      (make-parent-directory* destination)
      (call-with-output-file destination
        #:exists 'truncate/replace
        (lambda (out) (display "verified" out)))
      destination)
    (define successful (make-test-updater root successful-download))
    (define mutable-version (string-copy "1.0.0"))
    (define copied-input
      (make-test-updater root successful-download
                         #:current-version mutable-version))
    (string-set! mutable-version 0 #\9)
    (check-equal? (hash-ref (updater-state copied-input) 'currentVersion)
                  "1.0.0")
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-updater
                  #:application-id "dev.rivet.invalid"
                  #:current-version "1.0.0"
                  #:platform 'freebsd
                  #:architecture 'x64
                  #:public-key 'test-key
                  #:key-id "test-2026"
                  #:manifest-url "https://updates.example/update.json"
                  #:data-directory root
                  #:rollout-bucket 1)))
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-updater
                  #:application-id "dev.rivet.invalid"
                  #:current-version "1.0.0"
                  #:platform 'windows
                  #:architecture 'riscv64
                  #:public-key 'test-key
                  #:key-id "test-2026"
                  #:manifest-url "https://updates.example/update.json"
                  #:data-directory root
                  #:rollout-bucket 1)))
    (check-true (immutable? (updater-state successful)))
    (check-true
     (immutable? (hash-ref (updater-state successful) 'currentVersion)))
    (define available (updater-check! successful))
    (check-true (immutable? (hash-ref available 'availableVersion)))
    (check-true (immutable? (hash-ref available 'publishedAt)))
    (check-equal? (hash-ref available 'status) "available")
    (check-equal? (hash-ref (updater-state successful) 'phase) "available")
    (check-equal? (hash-ref (updater-state successful) 'availableVersion)
                  "2.0.0")
    (updater-download! successful)
    (define completed (updater-wait successful 2.0))
    (check-not-false completed)
    (check-equal? (hash-ref completed 'phase) "downloaded")
    (check-equal? (hash-ref completed 'percent) 100)
    (check-true (file-exists? (hash-ref completed 'downloadedPath)))
    (check-false (updater-cancel! successful))

    ;; Only one operation owns an updater. Cancellation interrupts the worker
    ;; and produces a stable terminal state instead of leaking exn:break.
    (define cancel-started (make-semaphore 0))
    (define (blocking-download _config _candidate _destination
                               #:on-progress on-progress
                               #:progress-every _progress-every)
      (on-progress 0)
      (semaphore-post cancel-started)
      (sync never-evt))
    (define cancellable (make-test-updater root blocking-download))
    (check-equal? (hash-ref (updater-check! cancellable) 'status) "available")
    (updater-download! cancellable)
    (check-not-false (sync/timeout 2 cancel-started))
    (check-exn #rx"another updater operation"
               (lambda () (updater-download! cancellable)))
    (check-true (updater-cancel! cancellable))
    (define cancelled (updater-wait cancellable 2.0))
    (check-not-false cancelled)
    (check-equal? (hash-ref cancelled 'phase) "cancelled")
    (check-equal? (hash-ref cancelled 'message)
                  "update download cancelled")

    ;; A server that neither produces bytes nor closes cannot leave the state
    ;; machine permanently in "downloading".
    (define stalled
      (make-test-updater root blocking-download
                         #:stall-timeout 0.05
                         #:total-timeout 1.0))
    (check-equal? (hash-ref (updater-check! stalled) 'status) "available")
    (updater-download! stalled)
    (define timed-out (updater-wait stalled 2.0))
    (check-not-false timed-out)
    (check-equal? (hash-ref timed-out 'phase) "error")
    (check-equal? (hash-ref timed-out 'message) "update download stalled")

    ;; Manifest acquisition has its own deadline; download watchdogs do not
    ;; help when a server stalls before selection begins.
    (define (blocking-fetch _url _key
                            #:key-id [_key-id #f]
                            #:maximum-bytes [_maximum-bytes (* 1024 1024)])
      (sync never-evt))
    (define check-bounded
      (make-test-updater root successful-download
                         #:check-timeout 0.05
                         #:fetch blocking-fetch))
    (define check-error (updater-check! check-bounded))
    (check-equal? (hash-ref check-error 'status) "error")
    (check-regexp-match #rx"deadline" (hash-ref check-error 'message))
    (check-equal? (hash-ref (updater-state check-bounded) 'phase) "error")

    ;; Breaking a synchronous check must also terminate its owned fetch
    ;; thread; otherwise an abandoned network request survives the caller.
    (define fetch-started (make-semaphore 0))
    (define fetch-stopped (make-semaphore 0))
    (define (interruptible-fetch _url _key
                                 #:key-id [_key-id #f]
                                 #:maximum-bytes [_maximum-bytes (* 1024 1024)])
      (dynamic-wind
        (lambda () (semaphore-post fetch-started))
        (lambda () (sync never-evt))
        (lambda () (semaphore-post fetch-stopped))))
    (define interrupted
      (make-test-updater root successful-download
                         #:check-timeout 10.0
                         #:fetch interruptible-fetch))
    (define checking-thread
      (thread
       (lambda ()
         (with-handlers ([exn:break? void])
           (updater-check! interrupted)))))
    (check-not-false (sync/timeout 2 fetch-started))
    (break-thread checking-thread)
    (check-not-false (sync/timeout 2 (thread-dead-evt checking-thread)))
    (check-not-false (sync/timeout 2 fetch-stopped))
    (check-equal? (hash-ref (updater-state interrupted) 'phase) "error")

    ;; ---- Silent-check throttle (issue #251) ----
    ;;
    ;; "Checked" means the check settled: an answer or a definitive failure.
    ;; The stamp lives behind the host's settings interface, so hosts stop
    ;; hand-rolling timestamps in three languages.
    (let* ([settings-mismatch-updater
            (lambda ()
              (make-test-updater root successful-download
                                 #:settings-get (lambda (key) #f)))]
           [fetch-count (box 0)]
           [counting-fetch
            (lambda _
              (set-box! fetch-count (add1 (unbox fetch-count)))
              manifest)]
           [failing-fetch (lambda _ (error 'fetch "connection refused"))]
           [broken-set! (lambda (key value) (error 'settings "disk full"))]
           [interfaceless (make-test-updater root successful-download)])
      (let-values ([(store-get store-set! store-table)
                    (make-settings-store)]
                   [(broken-get _broken-set! _broken-table)
                    (make-settings-store)]
                   [(bucket-get bucket-set! bucket-table)
                    (make-settings-store)])
        (let ([throttled-updater
               (make-test-updater root successful-download
                                  #:settings-get store-get
                                  #:settings-set! store-set!)]
              [counting-updater
               (make-test-updater root successful-download
                                  #:fetch counting-fetch
                                  #:silent-throttle-seconds 3600
                                  #:settings-get store-get
                                  #:settings-set! store-set!)]
              [failing-updater
               (make-test-updater root successful-download
                                  #:fetch failing-fetch
                                  #:settings-get store-get
                                  #:settings-set! store-set!)]
              [broken-updater
               (make-test-updater root successful-download
                                  #:settings-get broken-get
                                  #:settings-set! broken-set!)])
          (check-exn #rx"settings-get and settings-set! must be provided together"
                     (lambda () (settings-mismatch-updater)))
          ;; A fresh installation is due; a settled check stamps exactly once.
          (check-true (updater-silent-check-due? throttled-updater))
          (check-equal?
           (hash-ref (updater-silent-check! throttled-updater) 'status)
           "available")
          (check-true
           (exact-integer? (read-silent-check-stamp throttled-updater)))
          (check-equal? (hash-ref store-table silent-check-stamp-key)
                        (read-silent-check-stamp throttled-updater))
          (check-false (updater-silent-check-due? throttled-updater))

          ;; A throttled check never touches the network.
          (check-equal?
           (hash-ref (updater-silent-check! counting-updater) 'status)
           "throttled")
          (check-equal? (unbox fetch-count) 0)

          ;; A definitive transport failure settles the check: the error
          ;; result is returned and the stamp is still written, so an outage
          ;; cannot be retried in a tight loop.
          (hash-clear! store-table)
          (check-equal?
           (hash-ref (updater-silent-check! failing-updater) 'status) "error")
          (check-true
           (exact-integer? (read-silent-check-stamp failing-updater)))
          (check-false (updater-silent-check-due? failing-updater))

          ;; An expired stamp is due again.
          (hash-set! store-table silent-check-stamp-key
                     (- (current-seconds) (* 4 60 60)))
          (check-true (updater-silent-check-due? failing-updater))

          ;; A broken settings store cannot defeat the throttle: the memory
          ;; fallback keeps silent checks bounded for the process lifetime.
          (check-true (updater-silent-check-due? broken-updater))
          (check-equal?
           (hash-ref (updater-silent-check! broken-updater) 'status)
           "available")
          (check-true
           (exact-integer? (read-silent-check-stamp broken-updater)))
          (check-false (updater-silent-check-due? broken-updater))

          ;; Silent checks without a settings interface are a hard error.
          (check-exn #rx"silent checks require a settings interface"
                     (lambda () (updater-silent-check-due? interfaceless)))
          (check-exn #rx"silent checks require a settings interface"
                     (lambda () (updater-silent-check! interfaceless)))

          ;; ---- Sticky rollout bucket (issue #240 glue) ----
          (for ([_i (in-range 20)])
            (check-true (<= 0 (draw-rollout-bucket) 99)))
          (define first-bucket (resolve-rollout-bucket! bucket-get bucket-set!))
          (check-true (and (exact-integer? first-bucket)
                           (<= 0 first-bucket 99) #t))
          (check-equal? (hash-ref bucket-table "update-rollout-bucket")
                        first-bucket)
          ;; Sticky: the stored bucket wins on the next run.
          (check-equal? (resolve-rollout-bucket! bucket-get bucket-set!)
                        first-bucket)
          ;; Corrupt or out-of-range values redraw instead of propagating.
          (hash-set! bucket-table "update-rollout-bucket" 200)
          (check-true (<= 0 (resolve-rollout-bucket! bucket-get bucket-set!) 99))
          (check-false
           (equal? (hash-ref bucket-table "update-rollout-bucket") 200))
          ;; A store that cannot persist degrades to an unpersisted draw.
          (check-true
           (let ([bucket (resolve-rollout-bucket! #f #f)])
             (and (exact-integer? bucket) (<= 0 bucket 99))))))))
  (lambda () (delete-directory/files root)))
