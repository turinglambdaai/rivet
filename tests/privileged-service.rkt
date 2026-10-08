#lang racket/base

(require rackunit
         "../rivet/system.rkt")

(check-exn #rx"no native Rivet privileged-service adapter is installed"
           (lambda () (privileged-service-status 'demo)))

(define states (make-hash))
(define configs (make-hash))
(define adapter
  (privileged-service-adapter
   'test
   '(privileged-service reload)
   (lambda (service-id)
     (hash-ref states
               service-id
               (privileged-service-state 'stopped #f 0)))
   (lambda (service-id configuration)
     (hash-set! configs service-id configuration)
     (define state (privileged-service-state 'running #f 1))
     (hash-set! states service-id state)
     state)
   (lambda (service-id)
     (define previous
       (hash-ref states
                 service-id
                 (privileged-service-state 'stopped #f 0)))
     (define state
       (privileged-service-state
        'stopped
        #f
        (add1 (privileged-service-state-revision previous))))
     (hash-set! states service-id state)
     state)
   (lambda (service-id configuration)
     (hash-set! configs service-id configuration)
     (define previous
       (hash-ref states
                 service-id
                 (privileged-service-state 'stopped #f 0)))
     (define state
       (privileged-service-state
        'running
        #f
        (add1 (privileged-service-state-revision previous))))
     (hash-set! states service-id state)
     state)))

(parameterize ([current-privileged-service-adapter adapter])
  (check-equal? (privileged-service-capabilities)
                '(privileged-service reload))

  (define started (privileged-service-start! 'packet-tunnel #"config-v1"))
  (check-equal? (privileged-service-state-state started) 'running)
  (check-equal? (hash-ref configs 'packet-tunnel) #"config-v1")
  (check-equal? (privileged-service-status 'packet-tunnel) started)

  (define reloaded (privileged-service-reload! 'packet-tunnel #"config-v2"))
  (check-equal? (privileged-service-state-state reloaded) 'running)
  (check-equal? (privileged-service-state-revision reloaded) 2)
  (check-equal? (hash-ref configs 'packet-tunnel) #"config-v2")

  (define stopped (privileged-service-stop! 'packet-tunnel))
  (check-equal? (privileged-service-state-state stopped) 'stopped)
  (check-equal? (privileged-service-state-revision stopped) 3))

(check-exn exn:fail:contract?
           (lambda ()
             (parameterize ([current-privileged-service-adapter adapter])
               (privileged-service-start! 'packet-tunnel "not-bytes"))))

(check-exn exn:fail:contract?
           (lambda ()
             (parameterize ([current-privileged-service-adapter adapter])
               (privileged-service-status ""))))
