#lang racket/base

(require json
         racket/file
         racket/path
         racket/port)

(provide (struct-out settings-store)
         make-settings-store
         settings-ref
         settings-set!
         settings-remove!
         settings-snapshot)

(struct settings-store (path lock data) #:mutable #:transparent)

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
     value]))

(define (make-settings-store path)
  (settings-store (path->complete-path path)
                  (make-semaphore 1)
                  (load-settings path)))

(define (with-store-lock store thunk)
  (call-with-semaphore (settings-store-lock store) thunk))

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
     (hash-ref (settings-store-data store) (normalize-key 'settings-ref key) default))))

(define (settings-set! store key value)
  (with-store-lock
   store
   (lambda ()
     (persist! store
               (hash-set (settings-store-data store)
                         (normalize-key 'settings-set! key)
                         value))
     value)))

(define (settings-remove! store key)
  (with-store-lock
   store
   (lambda ()
     (persist! store
               (hash-remove (settings-store-data store)
                            (normalize-key 'settings-remove! key))))))

(define (settings-snapshot store)
  (with-store-lock store (lambda () (settings-store-data store))))
