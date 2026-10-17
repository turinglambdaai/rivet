#lang racket/base

;; The backend updater scaffolding every Rivet product hand-rolled: the
;; check/download flow against the distribution updater, a phase state box
;; the RVT1 layer can expose as an `update-state` event, and the family
;; silent-check throttle stamp.
;;
;; Throttle stamp semantics (family contract): a stamp means a check
;; *settled* — an answer or a definitive failure — never a merely attempted
;; one, so one offline launch cannot silence four hours of launches. The
;; stamp lives behind the product's settings interface; Rivet owns when it
;; is written and read.
;;
;; The operations are synchronous: `updater-runtime-check!` and
;; `updater-runtime-download!` settle before returning, and the phase box is
;; the only shared state, so products run them on their own worker thread
;; and the RVT1 layer observes through `updater-runtime-state`. The
;; `#:fetch` and `#:download` hooks exist for deterministic tests and for
;; products that route transport through an injected client; the defaults
;; are the real deadline-bounded updaters.

(require racket/file
         racket/match
         racket/random
         racket/string
         "manifest.rkt"
         "updater.rkt")

(provide (struct-out updater-settings-adapter)
         (struct-out updater-runtime)
         make-updater-runtime
         updater-runtime-state
         updater-runtime-check!
         updater-runtime-download!
         silent-check-due?
         mark-silent-checked!
         silent-check-interval-seconds
         draw-rollout-bucket
         resolve-rollout-bucket!)

;; Four hours, the family-wide silent-check interval.
(define silent-check-interval-seconds (* 4 60 60))
(define silent-check-stamp-key "updater.silent-check-stamp")

(struct updater-settings-adapter (get set!) #:transparent)

(struct updater-runtime
  (config destination-dir settings fetch download box silent-interval)
  #:transparent)

(define (fresh-phase)
  (hasheq 'status "idle" 'percent 0 'message "" 'downloaded_path #f))

(define (set-phase! box status
                    #:percent [percent #f]
                    #:message [message #f]
                    #:downloaded-path [downloaded-path 'unset])
  (define current (unbox box))
  (set-box!
   box
   (hasheq 'status status
           'percent (or percent (hash-ref current 'percent))
           'message (or message (hash-ref current 'message))
           'downloaded_path
           (if (eq? downloaded-path 'unset)
               (hash-ref current 'downloaded_path)
               downloaded-path))))

(define (make-updater-runtime #:config config
                              #:destination-dir destination-dir
                              #:settings settings
                              #:fetch [fetch fetch-update-manifest]
                              #:download [download download-update]
                              #:silent-interval-seconds
                              [silent-interval silent-check-interval-seconds])
  (unless (updater-config? config)
    (raise-argument-error 'make-updater-runtime "updater-config?" config))
  (unless (updater-settings-adapter? settings)
    (raise-argument-error 'make-updater-runtime
                          "updater-settings-adapter?" settings))
  (unless (and (real? silent-interval) (> silent-interval 0))
    (raise-argument-error 'make-updater-runtime
                          "positive real?" silent-interval))
  (updater-runtime config destination-dir settings fetch download
                   (box (fresh-phase)) silent-interval))

(define (updater-runtime-state runtime)
  (unbox (updater-runtime-box runtime)))

;; The stamp is a unix-seconds string written only when a check settles; a
;; missing or unparseable stamp counts as never checked.
(define (parse-stamp value)
  (define number
    (and (string? value) (string->number (string-trim value))))
  (and number (exact-positive-integer? number) number))

(define (silent-check-due? runtime now-seconds)
  (define adapter (updater-runtime-settings runtime))
  (define stamp
    (parse-stamp ((updater-settings-adapter-get adapter)
                  silent-check-stamp-key)))
  (or (not stamp)
      (>= (- now-seconds stamp)
          (updater-runtime-silent-interval runtime))))

(define (mark-silent-checked! runtime now-seconds)
  (define adapter (updater-runtime-settings runtime))
  ((updater-settings-adapter-set! adapter)
   silent-check-stamp-key (number->string now-seconds)))

;; ---- Sticky rollout bucket ----
;;
;; The #240 proposal pairs the throttle stamp with a persistent rollout
;; bucket: one 0-99 value per installation, drawn from OS entropy on first
;; run (racket/base's PRNG has a fixed seed) and recovered from the same
;; settings adapter afterwards. A corrupt stored value redraws; a store
;; that cannot persist degrades to an unpersisted draw so a broken store
;; cannot turn into an error at startup.

(define (draw-rollout-bucket)
  (modulo (integer-bytes->integer (crypto-random-bytes 4) #t #t) 100))

(define (resolve-rollout-bucket! settings [key "update.rollout-bucket"])
  (define get (updater-settings-adapter-get settings))
  ;; The writer cannot be named set!: (set! key value) would parse as the
  ;; assignment form and silently rebind the key parameter instead of
  ;; calling the adapter.
  (define write-value! (updater-settings-adapter-set! settings))
  (define stored
    (let ([value (get key)])
      (and (string? value)
           (let ([number (string->number (string-trim value))])
             (and number (exact-integer? number) (<= 0 number 99) number)))))
  (or stored
      (let ([bucket (draw-rollout-bucket)])
        (with-handlers ([exn:fail?
                         (lambda (e)
                           (eprintf "rollout-bucket persist diagnostic: ~a\n"
                                    (exn-message e)))])
          (write-value! key (number->string bucket)))
        bucket)))

(define (artifact-file-name artifact)
  (define url (update-artifact-url artifact))
  (substring url (add1 (string-last-index-of url #\/))))

(define (string-last-index-of text character)
  (let loop ([index (sub1 (string-length text))])
    (cond
      [(< index 0) 0]
      [(char=? (string-ref text index) character) index]
      [else (loop (sub1 index))])))

(define (updater-runtime-check! runtime)
  (set-phase! (updater-runtime-box runtime) "checking"
              #:percent 0 #:message "" #:downloaded-path #f)
  (with-handlers
      ([exn:fail?
        (lambda (error)
          ;; A definitive failure settles the check: the stamp is written
          ;; and the caller sees the error with the phase recorded.
          (mark-silent-checked! runtime (current-seconds))
          (set-phase! (updater-runtime-box runtime) "error" #:percent 0
                      #:message (exn-message error))
          (raise error))])
    (define manifest
      ((updater-runtime-fetch runtime)
       (updater-config-public-key (updater-runtime-config runtime))))
    (define candidate (select-update (updater-runtime-config runtime) manifest))
    (mark-silent-checked! runtime (current-seconds))
    (cond
      [candidate
       (set-phase!
        (updater-runtime-box runtime) "available" #:percent 100
        #:message
        (format "version ~a available"
                (update-manifest-version
                 (update-candidate-manifest candidate))))
       (updater-runtime-download! runtime candidate)
       candidate]
      [else
       (set-phase! (updater-runtime-box runtime) "idle" #:percent 0
                   #:message "no update available")
       #f])))

(define (updater-runtime-download! runtime candidate)
  (define destination
    (build-path (updater-runtime-destination-dir runtime)
                (artifact-file-name (update-candidate-artifact candidate))))
  (set-phase! (updater-runtime-box runtime) "downloading"
              #:percent 0 #:message "" #:downloaded-path #f)
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (set-phase! (updater-runtime-box runtime) "error"
                      #:message (exn-message error))
          (raise error))])
    (define path
      ((updater-runtime-download runtime)
       (updater-runtime-config runtime)
       candidate
       destination
       #:on-progress
       (lambda (bytes)
         (define total
           (update-artifact-size (update-candidate-artifact candidate)))
         (when (> total 0)
           (set-phase! (updater-runtime-box runtime)
                       "downloading"
                       #:percent (min 100 (quotient (* 100 bytes) total)))))))
    (set-phase! (updater-runtime-box runtime) "downloaded" #:percent 100
                #:downloaded-path (path->string path))
    path))
