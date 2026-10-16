#lang racket/base

;; The updater scaffolding: phase machine, settings-backed throttle stamp
;; semantics, and injected fetch/download for deterministic tests.

(require rackunit
         racket/file
         racket/path
         racket/string
         "../../rivet/distribution/manifest.rkt"
         "../../rivet/distribution/updater-scaffold.rkt"
         "../../rivet/distribution/updater.rkt")

;; --- settings adapter over a hash ------------------------------------------

(define (make-fake-settings)
  (define store (make-hasheq))
  (updater-settings-adapter
   (lambda (key) (hash-ref store key #f))
   (lambda (key value) (hash-set! store key value))))

(define config
  (updater-config "dev.rivet.test" "1.1.0" 'stable 'linux 'x64
                  (make-bytes 32 1) "release-2026" 0 (* 1024 1024) #f))

(define (sample-manifest #:version [version "1.2.0"])
  (update-manifest "dev.rivet.test" version 12 'stable
                   "2026-09-28T00:00:00Z" "1.0.0" "1.1.0"
                   #t 100
                   (list (update-artifact 'linux 'x64
                                          "https://updates.example/app.zip"
                                          (make-string 64 #\a)
                                          4 'zip '() #f))))

;; --- throttle stamp semantics ---------------------------------------------

(define (make-runtime settings #:fetch [fetch #f] #:download [download #f])
  (define kws
    (append '(#:config #:destination-dir #:settings)
            (if fetch (list '#:fetch) '())
            (if download (list '#:download) '())))
  (define vals
    (append (list config
                  (make-temporary-file "rivet-scaffold-~a" 'directory)
                  settings)
            (if fetch (list fetch) '())
            (if download (list download) '())))
  (keyword-apply make-updater-runtime kws vals '()))

(check-true
 (let ([runtime (make-runtime (make-fake-settings))])
   (begin0 (silent-check-due? runtime 1000)
           (delete-directory/files
            (updater-runtime-destination-dir runtime)))))
;; A missing stamp is due immediately.

;; A fresh stamp silences; the interval elapsing makes it due again.
(let ([settings (make-fake-settings)]
      [now 1000000])
  (define runtime (make-runtime settings))
  (mark-silent-checked! runtime now)
  (check-false (silent-check-due? runtime (+ now 1)))
  (check-false (silent-check-due? runtime (+ now silent-check-interval-seconds -1)))
  (check-true (silent-check-due? runtime (+ now silent-check-interval-seconds)))
  (delete-directory/files (updater-runtime-destination-dir runtime)))

;; A stamp written before a definitive failure would have happened still
;; counts — but the runtime stamps failures too, so an offline launch is
;; silent for the interval instead of retry-storming.
(let ([settings (make-fake-settings)]
      [now 2000000])
  (define runtime
    (make-runtime settings
                  #:fetch (lambda (public-key)
                            (error 'fetch "network unreachable"))))
  (check-exn exn:fail?
             (lambda () (updater-runtime-check! runtime)))
  (check-equal? (hash-ref (updater-runtime-state runtime) 'status) "error")
  (check-false (silent-check-due? runtime (+ now 1)))
  (check-true (silent-check-due? runtime (+ now silent-check-interval-seconds)))
  (delete-directory/files (updater-runtime-destination-dir runtime)))

;; --- check and download through the injected boundaries --------------------

(let* ([settings (make-fake-settings)]
       [runtime (make-runtime settings
                              #:fetch (lambda (public-key)
                                        (sample-manifest))
                              #:download
                              (lambda (config candidate destination
                                              #:on-progress [on-progress void])
                                (on-progress 2)
                                (on-progress 4)
                                (call-with-output-file destination
                                  (lambda (out) (write-bytes (make-bytes 4 9) out)))
                                destination))])
  (define candidate (updater-runtime-check! runtime))
  (check-true (update-candidate? candidate))
  (check-equal? (hash-ref (updater-runtime-state runtime) 'status) "downloaded")
  (check-equal? (hash-ref (updater-runtime-state runtime) 'percent) 100)
  (check-true (file-exists?
               (path->string
                (hash-ref (updater-runtime-state runtime) 'downloaded_path))))
  ;; The download progress went through the phase box.
  (check-true
   (>= (hash-ref (updater-runtime-state runtime) 'percent) 100))
  ;; The check settled, so the stamp was written.
  (check-false (silent-check-due? runtime (+ (current-seconds) 1)))
  (delete-directory/files (updater-runtime-destination-dir runtime)))

;; No update available settles back to idle and still stamps.
(let* ([settings (make-fake-settings)]
       [config-old
        (struct-copy updater-config config [current-version "9.9.9"])]
       [runtime
        (apply make-updater-runtime
               `(#:config ,config-old
                 #:destination-dir
                 ,(make-temporary-file "rivet-scaffold-~a" 'directory)
                 #:settings ,settings
                 #:fetch ,(lambda (public-key) (sample-manifest))))])
  (check-false (updater-runtime-check! runtime))
  (check-equal? (hash-ref (updater-runtime-state runtime) 'status) "idle")
  (check-equal? (hash-ref (updater-runtime-state runtime) 'message)
                "no update available")
  (check-false (silent-check-due? runtime (+ (current-seconds) 1)))
  (delete-directory/files (updater-runtime-destination-dir runtime)))

;; A download failure surfaces as an error phase with the message recorded.
(let* ([settings (make-fake-settings)]
       [runtime
        (make-runtime settings
                      #:fetch (lambda (public-key) (sample-manifest))
                      #:download
                      (lambda (config candidate destination
                                      #:on-progress [on-progress void])
                        (error 'download "connection reset")))])
  (check-exn exn:fail?
             (lambda () (updater-runtime-check! runtime)))
  (check-equal? (hash-ref (updater-runtime-state runtime) 'status) "error")
  (check-true (string-contains?
               (hash-ref (updater-runtime-state runtime) 'message)
               "connection reset"))
  (delete-directory/files (updater-runtime-destination-dir runtime)))
