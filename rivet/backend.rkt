#lang racket/base

(require ffi/unsafe/port
         racket/async-channel
         racket/match
         "protocol.rkt")

(provide define-rpc
         define-event
         emit-event!
         define-state
         state-ref
         state-set!
         serve
         serve-fds
         registered-rpcs
         registered-events
         registered-states
         rpc-schema
         event-schema
         state-schema
         (struct-out rpc-info)
         (struct-out event-info)
         (struct-out state-info))

(struct rpc-info (name arg-names arg-types result-type procedure) #:transparent)
(struct event-info (name type) #:transparent)
(struct state-info (name type cell lock) #:transparent)

(define registry (make-hash))
(define event-registry (make-hash))
(define state-registry (make-hash))
(define current-event-emitter (make-parameter #f))

(define (emit-event! name value)
  (unless (or (symbol? name) (string? name))
    (raise-argument-error 'emit-event! "(or/c symbol? string?)" name))
  (define emitter (current-event-emitter))
  (unless emitter
    (error 'emit-event! "no Rivet server is active on the current Racket thread"))
  (emitter (if (symbol? name) (symbol->string name) name) value))

(define (supported-type? type)
  (or (memq type '(String Int64 Bool Bytes Void Any))
      (match type
        [(list 'List inner) (supported-type? inner)]
        [(list 'Optional inner) (supported-type? inner)]
        [_ #f])))

(define (value-matches-type? type value)
  (case type
    [(String) (string? value)]
    [(Int64)
     (and (exact-integer? value)
          (<= (- (expt 2 63)) value (sub1 (expt 2 63))))]
    [(Bool) (boolean? value)]
    [(Bytes) (bytes? value)]
    [(Void) (void? value)]
    [(Any) #t]
    [else
     (match type
       [(list 'List inner)
        (and (list? value)
             (andmap (lambda (item) (value-matches-type? inner item)) value))]
       [(list 'Optional inner)
        (or (void? value) (value-matches-type? inner value))]
       [_ #f])]))

(define (validate-value who label type value)
  (unless (value-matches-type? type value)
    (raise-arguments-error who
                           "value does not match declared Rivet type"
                           "position" label
                           "expected" type
                           "value" value)))

(define (register-rpc! name arg-names arg-types result-type proc)
  (when (hash-has-key? registry name)
    (error 'define-rpc "RPC already registered: ~a" name))
  (for ([type (in-list (append arg-types (list result-type)))])
    (unless (supported-type? type)
      (raise-arguments-error 'define-rpc
                             "unsupported Rivet RPC type"
                             "rpc" name
                             "type" type)))
  (hash-set! registry name
             (rpc-info name arg-names arg-types result-type proc))
  (void))

(define (register-event! name type)
  (when (hash-has-key? event-registry name)
    (error 'define-event "Event already registered: ~a" name))
  (unless (supported-type? type)
    (raise-arguments-error 'define-event
                           "unsupported Rivet Event type"
                           "event" name
                           "type" type))
  (when (eq? type 'Void)
    (raise-arguments-error 'define-event
                           "Void is not a valid Event payload type"
                           "event" name))
  (hash-set! event-registry name (event-info name type))
  (void))

(define-syntax define-event
  (syntax-rules (:)
    [(_ name : type)
     (begin
       (register-event! 'name 'type)
       (define (name value)
         (validate-value 'name 'event 'type value)
         (emit-event! 'name value)))]
    [(_ name)
     (define-event name : Any)]))

(define (register-state! name type initial)
  (when (hash-has-key? state-registry name)
    (error 'define-state "state already registered: ~a" name))
  (unless (supported-type? type)
    (raise-arguments-error 'define-state
                           "unsupported Rivet state type"
                           "state" name
                           "type" type))
  (when (eq? type 'Void)
    (raise-arguments-error 'define-state
                           "Void is not a valid state type"
                           "state" name))
  (validate-value 'define-state name type initial)
  (define info (state-info name type (box initial) (make-semaphore 1)))
  (hash-set! state-registry name info)
  info)

(define-syntax define-state
  (syntax-rules (:)
    [(_ name : type initial)
     (define name (register-state! 'name 'type initial))]
    [(_ name type initial)
     (define name (register-state! 'name 'type initial))]))

(define (state-ref state)
  (unless (state-info? state)
    (raise-argument-error 'state-ref "state-info?" state))
  (call-with-semaphore
   (state-info-lock state)
   (lambda () (unbox (state-info-cell state)))))

(define (state-set! state value)
  (unless (state-info? state)
    (raise-argument-error 'state-set! "state-info?" state))
  (validate-value 'state-set! (state-info-name state) (state-info-type state) value)
  (call-with-semaphore
   (state-info-lock state)
   (lambda () (set-box! (state-info-cell state) value)))
  (define emitter (current-event-emitter))
  (when emitter
    (emitter "$state"
             (list (symbol->string (state-info-name state)) value)))
  (void))

(define (registered-rpcs)
  (sort (hash-values registry)
        string<?
        #:key (lambda (info) (symbol->string (rpc-info-name info)))))

(define (registered-events)
  (sort (hash-values event-registry)
        string<?
        #:key (lambda (info) (symbol->string (event-info-name info)))))

(define (registered-states)
  (sort (hash-values state-registry)
        string<?
        #:key (lambda (info) (symbol->string (state-info-name info)))))

(define (rpc-schema)
  (for/list ([info (in-list (registered-rpcs))])
    (hasheq
     'name (symbol->string (rpc-info-name info))
     'arguments
     (for/list ([name (in-list (rpc-info-arg-names info))]
                [type (in-list (rpc-info-arg-types info))])
       (hasheq 'name (symbol->string name)
               'type (format "~s" type)))
     'result (format "~s" (rpc-info-result-type info)))))

(define (event-schema)
  (for/list ([info (in-list (registered-events))])
    (hasheq 'name (symbol->string (event-info-name info))
            'type (format "~s" (event-info-type info)))))

(define (state-schema)
  (for/list ([info (in-list (registered-states))])
    (hasheq 'name (symbol->string (state-info-name info))
            'type (format "~s" (state-info-type info)))))

(define-syntax define-rpc
  (syntax-rules (:)
    [(_ (name [arg : arg-type] ... : result-type) body ...)
     (begin
       (define (name arg ...) body ...)
       (register-rpc! 'name '(arg ...) '(arg-type ...) 'result-type name))]
    [(_ (name [arg arg-type] ... : result-type) body ...)
     (begin
       (define (name arg ...) body ...)
       (register-rpc! 'name '(arg ...) '(arg-type ...) 'result-type name))]))

(define (request->call payload)
  (define value (decode-value payload))
  (match value
    [(list (? string? name) args ...)
     (values (string->symbol name) args)]
    [_
     (error 'serve "invalid RPC request payload: ~e" value)]))

(define (exn->payload e)
  (encode-value (exn-message e)))

(define (lookup-state name)
  (unless (string? name)
    (raise-argument-error '$state "string?" name))
  (hash-ref state-registry
            (string->symbol name)
            (lambda () (error '$state "unknown state: ~a" name))))

(define (invoke-state-request name args)
  (case name
    [($state/get)
     (match args
       [(list state-name) (state-ref (lookup-state state-name))]
       [_ (error '$state/get "expected state name")])]
    [($state/set)
     (match args
       [(list state-name value)
        (define state (lookup-state state-name))
        (state-set! state value)
        (state-ref state)]
       [_ (error '$state/set "expected state name and value")])]
    [else (error 'serve "unknown internal request: ~a" name)]))

(define (serve in out)
  (unless (input-port? in)
    (raise-argument-error 'serve "input-port?" in))
  (unless (output-port? out)
    (raise-argument-error 'serve "output-port?" out))

  (define root-custodian (make-custodian))
  (define responses (make-async-channel))
  (define pending (make-hash))
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
    (define internal-state-request?
      (memq rpc-name '($state/get $state/set)))
    (define info
      (and (not internal-state-request?)
           (hash-ref registry rpc-name
                     (lambda ()
                       (error 'serve "unknown RPC: ~a" rpc-name)))))
    (define request-custodian (make-custodian root-custodian))
    (hash-set! pending id request-custodian)
    (parameterize ([current-custodian request-custodian])
      (thread
       (lambda ()
         (with-handlers ([exn:fail?
                          (lambda (e)
                            (hash-remove! pending id)
                            (send! (frame message:error id (exn->payload e))))])
           (define result
             (if internal-state-request?
                 (invoke-state-request rpc-name args)
                 (let ([expected (length (rpc-info-arg-types info))])
                   (unless (= expected (length args))
                     (error rpc-name
                            "expected ~a argument~a, received ~a"
                            expected
                            (if (= expected 1) "" "s")
                            (length args)))
                   (for ([arg (in-list args)]
                         [arg-name (in-list (rpc-info-arg-names info))]
                         [arg-type (in-list (rpc-info-arg-types info))])
                     (validate-value rpc-name arg-name arg-type arg))
                   (let ([value (apply (rpc-info-procedure info) args)])
                     (validate-value rpc-name 'result (rpc-info-result-type info) value)
                     value))))
           (finish! id message:response result))))))

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
      (parameterize ([current-event-emitter emit!]
                     [exit-handler
                      (lambda (value)
                        (if (exn? value)
                            (raise value)
                            (error 'rivet/backend
                                   "backend requested exit: ~e"
                                   value)))])
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

(define (serve-fds in-fd out-fd)
  (unless (exact-integer? in-fd)
    (raise-argument-error 'serve-fds "exact-integer?" in-fd))
  (unless (exact-integer? out-fd)
    (raise-argument-error 'serve-fds "exact-integer?" out-fd))
  (define in (unsafe-file-descriptor->port in-fd 'rivet-in '(read)))
  (define out (unsafe-file-descriptor->port out-fd 'rivet-out '(write)))
  (dynamic-wind
    void
    (lambda ()
      (with-handlers ([exn?
                       (lambda (e)
                         ((error-display-handler)
                          (format "Rivet backend terminated: ~a"
                                  (exn-message e))
                          e)
                         (void))])
        (serve in out)))
    (lambda ()
      (unless (port-closed? in) (close-input-port in))
      (unless (port-closed? out) (close-output-port out)))))
