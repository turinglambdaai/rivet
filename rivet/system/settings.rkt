#lang racket/base

(require json
         racket/file
         racket/path
         racket/port)

(provide settings-store?
         make-settings-store
         settings-ref
         settings-set!
         settings-remove!
         settings-snapshot)

;; The path, lock, and cached data form one synchronization invariant.  Keep
;; the representation private so callers cannot replace any one of them and
;; then continue through the public operations with a corrupted store.
(struct settings-store (path lock data) #:mutable)

(define store-locks (make-hash))
(define store-locks-guard (make-semaphore 1))

(define (shared-store-lock path)
  (define key (path->string (normal-case-path path)))
  (call-with-semaphore
   store-locks-guard
   (lambda ()
     (hash-ref store-locks key
               (lambda ()
                 (define lock (make-semaphore 1))
                 (hash-set! store-locks key lock)
                 lock)))))

(define (immutable-settings-value value)
  (cond
    [(hash? value)
     (for/hasheq ([(key item) (in-hash value)])
       (values key (immutable-settings-value item)))]
    [(list? value) (map immutable-settings-value value)]
    [(string? value) (string->immutable-string value)]
    [else value]))

(define (load-settings path)
  (cond
    [(not (file-exists? path)) (hasheq)]
    [else
     (define value
       (call-with-input-file path read-json #:mode 'text))
     (unless (hash? value)
       (raise-arguments-error 'make-settings-store
                              "settings file must contain a JSON object"
                              "path" path))
     (immutable-settings-value value)]))

(define (make-settings-store path)
  (define complete-path (path->complete-path path))
  (settings-store complete-path
                  (shared-store-lock complete-path)
                  (load-settings complete-path)))

(define (store-lock-path store)
  (path-add-extension (settings-store-path store) #".lock"))

(define (with-store-lock store thunk)
  (call-with-semaphore
   (settings-store-lock store)
   (lambda ()
     (define lock-path (store-lock-path store))
     (make-parent-directory* lock-path)
     (call-with-file-lock/timeout
      #f
      'exclusive
      thunk
      (lambda ()
        (raise-arguments-error
         'settings-store
         "another process owns the settings transaction"
         "lock" lock-path))
      #:lock-file lock-path
      #:max-delay 2.0))))

(define (refresh! store)
  (define data (load-settings (settings-store-path store)))
  (set-settings-store-data! store data)
  data)

(define (persist! store data)
  (define path (settings-store-path store))
  (make-parent-directory* path)
  (call-with-atomic-output-file path
    (lambda (out temporary-path)
      (void temporary-path)
      (write-json data out)
      (newline out)))
  (set-settings-store-data! store data))

(define (normalize-key who key)
  (cond
    [(symbol? key) key]
    [(string? key) (string->symbol key)]
    [else (raise-argument-error who "(or/c symbol? string?)" key)]))

(define (settings-ref store key [default #f])
  (with-store-lock
   store
   (lambda ()
     (hash-ref (refresh! store) (normalize-key 'settings-ref key) default))))

(define (settings-set! store key value)
  (with-store-lock
   store
   (lambda ()
     (define safe-value (immutable-settings-value value))
     (persist! store
               (hash-set (refresh! store)
                         (normalize-key 'settings-set! key)
                         safe-value))
     safe-value)))

(define (settings-remove! store key)
  (with-store-lock
   store
   (lambda ()
     (persist! store
               (hash-remove (refresh! store)
                            (normalize-key 'settings-remove! key))))))

(define (settings-snapshot store)
  (with-store-lock store (lambda () (refresh! store))))
