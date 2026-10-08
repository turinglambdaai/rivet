#lang racket/base

(require rackunit
         "../rivet/system.rkt")

(check-exn #rx"no native Rivet privileged-service adapter is installed"
           (lambda () (privileged-service-status 'demo)))

(define states (make-hash))
(define configs (make-hash))
(define received-config (box #f))
(define adapter
  (privileged-service-adapter
   'test
   '(privileged-service reload)
   (lambda (service-id)
     (hash-ref states
               service-id
               (privileged-service-state 'stopped #f 0)))
   (lambda (service-id configuration)
     (set-box! received-config configuration)
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

  (define mutable-config (bytes-copy #"config-v1"))
  (define started (privileged-service-start! 'packet-tunnel mutable-config))
  (bytes-set! mutable-config 0 (char->integer #\X))
  (check-equal? (privileged-service-state-state started) 'running)
  (check-equal? (hash-ref configs 'packet-tunnel) #"config-v1")
  (check-true (immutable? (unbox received-config)))
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

(check-exn exn:fail?
           (lambda ()
             (current-privileged-service-adapter
              (privileged-service-adapter
               'bad-capabilities
               '(valid 42)
               void void void void))))

(define invalid-state-adapter
  (privileged-service-adapter
   'invalid-state
   '()
   (lambda (_service-id)
     (privileged-service-state 'running (make-string 4097 #\x) 0))
   (lambda (_service-id _configuration) 'not-a-state)
   (lambda (_service-id) (privileged-service-state 'stopped #f -1))
   (lambda (_service-id _configuration)
     (privileged-service-state "running" #f 1))))

(parameterize ([current-privileged-service-adapter invalid-state-adapter])
  (check-exn #rx"oversized state detail"
             (lambda () (privileged-service-status 'packet-tunnel)))
  (check-exn #rx"non-state result"
             (lambda ()
               (privileged-service-start! 'packet-tunnel #"config")))
  (check-exn #rx"invalid state revision"
             (lambda () (privileged-service-stop! 'packet-tunnel)))
  (check-exn #rx"non-symbol lifecycle"
             (lambda ()
               (privileged-service-reload! 'packet-tunnel #"config"))))
