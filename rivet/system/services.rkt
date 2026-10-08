#lang racket/base

(require racket/contract/base)

(provide (struct-out system-adapter)
         current-system-adapter
         system-capabilities
         acquire-single-instance!
         register-activation-handler!
         show-system-notification!
         set-tray-menu!
         set-autostart!
         autostart-enabled?
         secure-store-set!
         secure-store-ref
         secure-store-remove!
         install-crash-hook!)

;; Racket-side providers, tests, and headless tools may install an adapter.
;; Generated native hosts use the first-party Swift/C++ system libraries
;; directly; they do not move native UI objects or Racket procedures across
;; the RVT1 boundary.
(struct system-adapter
  (name capabilities acquire-single-instance register-activation-handler
        show-notification set-tray-menu set-autostart autostart-enabled
        secure-store-set secure-store-ref secure-store-remove install-crash-hook)
  #:transparent)

(define (unsupported operation)
  (lambda args
    (error operation
           "no Racket system-service provider is installed; parameterize current-system-adapter or call the native host system API")))

(define unavailable-adapter
  (system-adapter
   'unavailable '()
   (unsupported 'acquire-single-instance!)
   (unsupported 'register-activation-handler!)
   (unsupported 'show-system-notification!)
   (unsupported 'set-tray-menu!)
   (unsupported 'set-autostart!)
   (unsupported 'autostart-enabled?)
   (unsupported 'secure-store-set!)
   (unsupported 'secure-store-ref)
   (unsupported 'secure-store-remove!)
   (unsupported 'install-crash-hook!)))

(define current-system-adapter
  (make-parameter
   unavailable-adapter
   (lambda (value)
     (unless (system-adapter? value)
       (raise-argument-error 'current-system-adapter "system-adapter?" value))
     value)))

(define (system-capabilities)
  (system-adapter-capabilities (current-system-adapter)))

(define (call-adapter accessor . arguments)
  (apply (accessor (current-system-adapter)) arguments))

(define (acquire-single-instance! application-id activation)
  (call-adapter system-adapter-acquire-single-instance application-id activation))

(define (register-activation-handler! handler)
  (call-adapter system-adapter-register-activation-handler handler))

(define (show-system-notification! title body #:tag [tag #f])
  (call-adapter system-adapter-show-notification title body tag))

(define (set-tray-menu! items)
  (call-adapter system-adapter-set-tray-menu items))

(define (set-autostart! enabled?)
  (call-adapter system-adapter-set-autostart enabled?))

(define (autostart-enabled?)
  (call-adapter system-adapter-autostart-enabled))

(define (secure-store-set! service account secret)
  (unless (bytes? secret)
    (raise-argument-error 'secure-store-set! "bytes?" secret))
  (call-adapter system-adapter-secure-store-set service account secret))

(define (secure-store-ref service account [default #f])
  (call-adapter system-adapter-secure-store-ref service account default))

(define (secure-store-remove! service account)
  (call-adapter system-adapter-secure-store-remove service account))

(define (install-crash-hook! handler)
  (call-adapter system-adapter-install-crash-hook handler))
