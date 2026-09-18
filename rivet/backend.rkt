#lang racket/base

(require ffi/unsafe/port
         racket/async-channel
         racket/match
         "protocol.rkt")

(provide define-rpc
         define-event
         emit-event!
         serve
         serve-fds
         registered-rpcs
         (struct-out rpc-info))

(struct rpc-info (name arg-types result-type procedure) #:transparent)

(define registry (make-hash))
(define current-event-emitter (make-parameter #f))

(define (emit-event! name value)
  (unless (or (symbol? name) (string? name))
    (raise-argument-error 'emit-event! "(or/c symbol? string?)" name))
  (define emitter (current-event-emitter))
  (unless emitter
    (error 'emit-event! "no Rivet server is active on the current Racket thread"))
  (emitter (if (symbol? name) (symbol->string name) name) value))

(define-syntax-rule (define-event name)
  (define (name value)
    (emit-event! 'name value)))


(define (register-rpc! name arg-types result-type proc)
  (when (hash-has-key? registry name)
    (error 'define-rpc "RPC already registered: ~a" name))
  (hash-set! registry name (rpc-info name arg-types result-type proc))
  (void))

(define (registered-rpcs)
  (sort (hash-values registry)
        string<?
        #:key (lambda (info) (symbol->string (rpc-info-name info)))))

;; Intentionally small v0 syntax. Types are schema metadata today; the wire
;; codec validates values. Code generators will consume this schema later.
(define-syntax define-rpc
  (syntax-rules (:)
    [(_ (name [arg arg-type] ... : result-type) body ...)
     (begin
       (define (name arg ...) body ...)
       (register-rpc! 'name '(arg-type ...) 'result-type name))]))

(define (request->call payload)
  (define value (decode-value payload))
  (match value
    [(list (? string? name) args ...)
     (values (string->symbol name) args)]
    [_
     (error 'serve "invalid RPC request payload: ~e" value)]))

(define (exn->payload e)
  (encode-value (exn-message e)))

;; Runs the Rivet RPC server on binary ports. The native host owns the Racket
;; runtime thread; this server owns lightweight Racket threads for individual
;; calls. Responses are serialized by one writer thread so frames cannot
;; interleave on the output port.
(define (serve in out)
  (unless (input-port? in)
    (raise-argument-error 'serve "input-port?" in))
  (unless (output-port? out)
    (raise-argument-error 'serve "output-port?" out))

  (define root-custodian (make-custodian))
  (define responses (make-async-channel))
  (define pending (make-hash)) ; request id -> request custodian
  (define stopped? #f)
  (define next-event-id 1)

  (define writer
    (parameterize ([current-custodian root-custodian])
      (thread
       (lambda ()
         (let loop ()
           (define response (async-channel-get responses))
           (unless (eq? response 'stop)
             (write-frame response out)
             (loop)))))))

  (define (send! f)
    (async-channel-put responses f))

  (define (finish! id type value)
    (hash-remove! pending id)
    (send! (frame type id (encode-value value))))

  (define (emit! name value)
    (define id next-event-id)
    (set! next-event-id (add1 next-event-id))
    (send! (frame message:event id (encode-value (list name value)))))

  (define (start-request! f)
    (define id (frame-id f))
    (when (hash-has-key? pending id)
      (error 'serve "duplicate request id: ~a" id))
    (define-values (rpc-name args) (request->call (frame-payload f)))
    (define info
      (hash-ref registry rpc-name
                (lambda ()
                  (error 'serve "unknown RPC: ~a" rpc-name))))
    (define request-custodian (make-custodian root-custodian))
    (hash-set! pending id request-custodian)
    (parameterize ([current-custodian request-custodian])
      (thread
       (lambda ()
         (with-handlers ([exn:fail?
                          (lambda (e)
                            (hash-remove! pending id)
                            (send! (frame message:error id (exn->payload e))))])
           (define expected (length (rpc-info-arg-types info)))
           (unless (= expected (length args))
             (error rpc-name
                    "expected ~a argument~a, received ~a"
                    expected
                    (if (= expected 1) "" "s")
                    (length args)))
           (finish! id
                    message:response
                    (apply (rpc-info-procedure info) args)))))))

  (define (cancel! id)
    (define request-custodian (hash-ref pending id #f))
    (when request-custodian
      (custodian-shutdown-all request-custodian)
      (hash-remove! pending id)
      (send! (frame message:error id (encode-value "request cancelled")))))

  (define (dispatch! f)
    (case (frame-type f)
      [(2) (start-request! f)]
      [(6) (cancel! (frame-id f))]
      [(7) (set! stopped? #t)]
      [else
       (send! (frame message:error
                     (frame-id f)
                     (encode-value
                      (format "unsupported message type: ~a"
                              (frame-type f)))))]))

  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-event-emitter emit!])
        (send! (frame message:hello 0
                      (encode-value (list "rivet" protocol-version))))
        (let loop ()
          (unless stopped?
            (let ([f (read-frame in)])
              (if (eof-object? f)
                  (set! stopped? #t)
                  (begin
                    (dispatch! f)
                    (loop))))))))
    (lambda ()
      (for ([cust (in-hash-values pending)])
        (custodian-shutdown-all cust))
      (hash-clear! pending)
      (async-channel-put responses 'stop)
      (thread-wait writer)
      (custodian-shutdown-all root-custodian)))

  (void))

;; Native hosts deal in OS/CRT file descriptors. Keeping the conversion here
;; means platform hosts never need to manufacture Racket port objects through
;; the embedding API. `unsafe-file-descriptor->port` does not duplicate the
;; descriptor, so this procedure owns the two descriptors for its lifetime.
(define (serve-fds in-fd out-fd)
  (unless (exact-integer? in-fd)
    (raise-argument-error 'serve-fds "exact-integer?" in-fd))
  (unless (exact-integer? out-fd)
    (raise-argument-error 'serve-fds "exact-integer?" out-fd))
  (define in (unsafe-file-descriptor->port in-fd 'rivet-in '(read)))
  (define out (unsafe-file-descriptor->port out-fd 'rivet-out '(write)))
  (dynamic-wind
    void
    (lambda () (serve in out))
    (lambda ()
      (unless (port-closed? in) (close-input-port in))
      (unless (port-closed? out) (close-output-port out)))))
