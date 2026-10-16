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
                           #:fetch [fetch fake-fetch])
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
     #:total-timeout total-timeout)))

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
    (check-equal? (hash-ref (updater-state interrupted) 'phase) "error"))
  (lambda () (delete-directory/files root)))
