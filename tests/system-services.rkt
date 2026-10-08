#lang racket/base

(require json
         rackunit
         racket/file
         "../rivet/system.rkt")

(define settings-path (make-temporary-file "rivet-settings-~a.json"))
(delete-file settings-path)
(dynamic-wind
  void
  (lambda ()
    (define store (make-settings-store settings-path))
    (check-equal? (settings-ref store 'theme "system") "system")
    (settings-set! store 'theme "dark")
    (check-equal? (settings-ref store "theme") "dark")
    (define reloaded (make-settings-store settings-path))
    (check-equal? (settings-ref reloaded 'theme) "dark")
    (settings-remove! reloaded 'theme)
    (check-false (settings-ref reloaded 'theme #f)))
  (lambda () (when (file-exists? settings-path) (delete-file settings-path))))

(define secrets (make-hash))
(define notifications '())
(define adapter
  (system-adapter
   'test '(single-instance notification tray autostart secure-storage crash-hook)
   (lambda (_app _activation) #t)
   (lambda (_handler) (void))
   (lambda (title body tag) (set! notifications (cons (list title body tag) notifications)))
   (lambda (_items) (void))
   (lambda (_enabled) (void))
   (lambda () #f)
   (lambda (service account value) (hash-set! secrets (cons service account) value))
   (lambda (service account default) (hash-ref secrets (cons service account) default))
   (lambda (service account) (hash-remove! secrets (cons service account)))
   (lambda (_handler) (void))))

(check-equal? (system-capabilities) '())
(check-exn #rx"no Racket system-service provider is installed"
           (lambda () (autostart-enabled?)))

(parameterize ([current-system-adapter adapter])
  (check-true (acquire-single-instance! "dev.rivet.test" '()))
  (show-system-notification! "Ready" "Rivet is ready" #:tag "ready")
  (check-equal? notifications '(("Ready" "Rivet is ready" "ready")))
  (secure-store-set! "service" "account" #"secret")
  (check-equal? (secure-store-ref "service" "account") #"secret")
  (secure-store-remove! "service" "account")
  (check-false (secure-store-ref "service" "account" #f)))

(define records '())
(parameterize ([current-rivet-log-sink (lambda (record) (set! records (cons record records)))]
               [current-rivet-crash-reporter (lambda (_record _exception) (void))])
  (check-exn #rx"boom"
             (lambda ()
               (call-with-crash-reporting (lambda () (error 'test "boom")))))
  (check-equal? (hash-ref (car records) 'event) "unhandled-exception"))
