#lang racket/base

(require json
         racket/date)

(provide current-rivet-log-sink
         current-rivet-crash-reporter
         rivet-log
         call-with-crash-reporting)

(define current-rivet-log-sink
  (make-parameter
   (lambda (record)
     (write-json record (current-error-port))
     (newline (current-error-port)))))

(define current-rivet-crash-reporter
  (make-parameter (lambda (record exception) (void record exception))))

(define (rivet-log level event #:fields [fields (hasheq)])
  (unless (memq level '(debug info warning error critical))
    (raise-argument-error 'rivet-log
                          "'debug, 'info, 'warning, 'error, or 'critical"
                          level))
  (unless (hash? fields)
    (raise-argument-error 'rivet-log "hash?" fields))
  (define record
    (hash-set*
     fields
     'timestamp (date->string (seconds->date (current-seconds) #t) #t)
     'level (symbol->string level)
     'event event))
  ((current-rivet-log-sink) record)
  record)

(define (call-with-crash-reporting thunk #:context [context (hasheq)])
  (with-handlers ([exn:fail?
                   (lambda (exception)
                     (define record
                       (rivet-log 'critical
                                  "unhandled-exception"
                                  #:fields
                                  (hash-set context 'message
                                            (exn-message exception))))
                     ((current-rivet-crash-reporter) record exception)
                     (raise exception))])
    (thunk)))
