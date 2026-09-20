#lang racket/base

(require ffi/unsafe/port
         racket/async-channel
         racket/list
         racket/match
         "protocol.rkt")

(provide define-rpc
         define-event
         emit-event!
         define-state
         state-ref
         state-set!
         define-record
         record-ref
         serve
         serve-fds
         registered-rpcs
         registered-states
         registered-records
         rpc-schema
         state-schema
         record-schema
         (struct-out rpc-info)
         (struct-out state-info)
         (struct-out record-info)
         (struct-out record-value))

(struct rpc-info (name arg-names arg-types result-type procedure) #:transparent)
(struct state-info (name type cell lock) #:transparent)
(struct record-info (name field-names field-types) #:transparent)
(struct record-value (name fields) #:transparent)

(define registry (make-hash))
(define state-registry (make-hash))
(define record-registry (make-hash))
(define current-event-emitter (make-parameter #f))

(define primitive-types '(String Int64 Bool Bytes Void Any))

(define (lookup-record-info type [failure #f])
  (and (symbol? type)
       (hash-ref record-registry type failure)))

(define (supported-type? type)
  (or (memq type primitive-types)
      (and (symbol? type) (hash-has-key? record-registry type))
      (match type
        [(list 'List inner) (supported-type? inner)]
        [(list 'Optional inner) (supported-type? inner)]
        [_ #f])))

(define (validate-type! who owner type)
  (unless (supported-type? type)
    (raise-arguments-error who
                           "unsupported Rivet type"
                           "owner" owner
                           "type" type)))

(define (register-record! name field-names field-types)
  (when (hash-has-key? record-registry name)
    (error 'define-record "Record already registered: ~a" name))
  (unless (= (length field-names) (length field-types))
    (error 'define-record "field name/type count mismatch for ~a" name))
  (when (check-duplicates field-names)
    (raise-arguments-error 'define-record
                           "record field names must be unique"
                           "record" name
                           "fields" field-names))
  (for ([type (in-list field-types)])
    (validate-type! 'define-record name type))
  (define info (record-info name field-names field-types))
  (hash-set! record-registry name info)
  info)

(define-syntax define-record
  (syntax-rules (:)
    [(_ name ([field : field-type] ...))
     (begin
       (define (name field ...)
         (record-value 'name (list field ...)))
       (register-record! 'name '(field ...) '(field-type ...)))]
    [(_ name ([field field-type] ...))
     (begin
       (define (name field ...)
         (record-value 'name (list field ...)))
       (register-record! 'name '(field ...) '(field-type ...)))]))

(define (record-ref value field)
  (unless (record-value? value)
    (raise-argument-error 'record-ref "record-value?" value))
  (define info
    (hash-ref record-registry
              (record-value-name value)
              (lambda ()
                (error 'record-ref "unknown record type: ~a" (record-value-name value)))))
  (define field-symbol
    (cond
      [(symbol? field) field]
      [(string? field) (string->symbol field)]
      [else (raise-argument-error 'record-ref "(or/c symbol? string?)" field)]))
  (define index (index-of (record-info-field-names info) field-symbol))
  (unless index
    (error 'record-ref "unknown field ~a on record ~a"
           field-symbol (record-info-name info)))
  (list-ref (record-value-fields value) index))

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
     (cond
       [(and (symbol? type) (hash-has-key? record-registry type))
        (define info (hash-ref record-registry type))
        (and (record-value? value)
             (eq? (record-value-name value) type)
             (= (length (record-value-fields value))
                (length (record-info-field-types info)))
             (for/and ([field-value (in-list (record-value-fields value))]
                       [field-type (in-list (record-info-field-types info))])
               (value-matches-type? field-type field-value)))]
       [else
        (match type
          [(list 'List inner)
           (and (list? value)
                (andmap (lambda (item) (value-matches-type? inner item)) value))]
          [(list 'Optional inner)
           (or (void? value) (value-matches-type? inner value))]
          [_ #f])])]))

(define (validate-value who label type value)
  (unless (value-matches-type? type value)
    (raise-arguments-error who
                           "value does not match declared Rivet type"
                           "position" label
                           "expected" type
                           "value" value)))

;; Record is a schema/type-system feature layered on RVT1. The wire protocol
;; remains version 1: a record is encoded as a list in its declared field order.
;; This keeps old runtimes compatible while generated clients expose named DTOs.
(define (typed->wire type value)
  (case type
    [(Any) (wire-safe-value value)]
    [(String Int64 Bool Bytes Void) value]
    [else
     (cond
       [(and (symbol? type) (hash-has-key? record-registry type))
        (validate-value 'typed->wire 'value type value)
        (define info (hash-ref record-registry type))
        (for/list ([field-value (in-list (record-value-fields value))]
                   [field-type (in-list (record-info-field-types info))])
          (typed->wire field-type field-value))]
       [else
        (match type
          [(list 'List inner)
           (for/list ([item (in-list value)]) (typed->wire inner item))]
          [(list 'Optional inner)
           (if (void? value) (void) (typed->wire inner value))]
          [_ (error 'typed->wire "unsupported type: ~e" type)])])]))

(define (wire->typed type value)
  (case type
    [(Any) value]
    [(String Int64 Bool Bytes Void) value]
    [else
     (cond
       [(and (symbol? type) (hash-has-key? record-registry type))
        (define info (hash-ref record-registry type))
        (unless (list? value)
          (raise-arguments-error 'wire->typed
                                 "record wire value must be a list"
                                 "record" type
                                 "value" value))
        (unless (= (length value) (length (record-info-field-types info)))
          (raise-arguments-error 'wire->typed
                                 "record wire field count mismatch"
                                 "record" type
                                 "expected" (length (record-info-field-types info))
                                 "received" (length value)))
        (record-value
         type
         (for/list ([field-value (in-list value)]
                    [field-type (in-list (record-info-field-types info))])
           (wire->typed field-type field-value)))]
       [else
        (match type
          [(list 'List inner)
           (unless (list? value)
             (raise-arguments-error 'wire->typed
                                    "list wire value must be a list"
                                    "type" type
                                    "value" value))
           (for/list ([item (in-list value)]) (wire->typed inner item))]
          [(list 'Optional inner)
           (if (void? value) (void) (wire->typed inner value))]
          [_ (error 'wire->typed "unsupported type: ~e" type)])])]))

(define (wire-safe-value value)
  (cond
    [(record-value? value)
     (typed->wire (record-value-name value) value)]
    [(list? value) (map wire-safe-value value)]
    [else value]))

(define (emit-event! name value)
  (unless (or (symbol? name) (string? name))
    (raise-argument-error 'emit-event! "(or/c symbol? string?)" name))
  (define emitter (current-event-emitter))
  (unless emitter
    (error 'emit-event! "no Rivet server is active on the current Racket thread"))
  (emitter (if (symbol? name) (symbol->string name) name)
           (wire-safe-value value)))

(define-syntax-rule (define-event name)
  (define (name value)
    (emit-event! 'name value)))

(define (register-rpc! name arg-names arg-types result-type proc)
  (when (hash-has-key? registry name)
    (error 'define-rpc "RPC already registered: ~a" name))
  (for ([type (in-list (append arg-types (list result-type)))])
    (validate-type! 'define-rpc name type))
  (hash-set! registry name
             (rpc-info name arg-names arg-types result-type proc))
  (void))

(define (register-state! name type initial)
  (when (hash-has-key? state-registry name)
    (error 'define-state "state already registered: ~a" name))
  (validate-type! 'define-state name type)
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
             (list (symbol->string (state-info-name state))
                   (typed->wire (state-info-type state) value))))
  (void))

(define (registered-rpcs)
  (sort (hash-values registry)
        string<?
        #:key (lambda (info) (symbol->string (rpc-info-name info)))))

(define (registered-states)
  (sort (hash-values state-registry)
        string<?
        #:key (lambda (info) (symbol->string (state-info-name info)))))

(define (registered-records)
  (sort (hash-values record-registry)
        string<?
        #:key (lambda (info) (symbol->string (record-info-name info)))))

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

(define (state-schema)
  (for/list ([info (in-list (registered-states))])
    (hasheq 'name (symbol->string (state-info-name info))
            'type (format "~s" (state-info-type info)))))

(define (record-schema)
  (for/list ([info (in-list (registered-records))])
    (hasheq
     'name (symbol->string (record-info-name info))
     'fields
     (for/list ([name (in-list (record-info-field-names info))]
                [type (in-list (record-info-field-types info))])
       (hasheq 'name (symbol->string name)
               'type (format "~s" type))))))

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
       [(list state-name)
        (define state (lookup-state state-name))
        (typed->wire (state-info-type state) (state-ref state))]
       [_ (error '$state/get "expected state name")])]
    [($state/set)
     (match args
       [(list state-name wire-value)
        (define state (lookup-state state-name))
        (define value (wire->typed (state-info-type state) wire-value))
        (state-set! state value)
        (typed->wire (state-info-type state) (state-ref state))]
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
    (send! (frame message:event id
                  (encode-value (list name (wire-safe-value value))))))

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
                   (define typed-args
                     (for/list ([arg (in-list args)]
                                [arg-type (in-list (rpc-info-arg-types info))])
                       (wire->typed arg-type arg)))
                   (for ([arg (in-list typed-args)]
                         [arg-name (in-list (rpc-info-arg-names info))]
                         [arg-type (in-list (rpc-info-arg-types info))])
                     (validate-value rpc-name arg-name arg-type arg))
                   (let ([value (apply (rpc-info-procedure info) typed-args)])
                     (validate-value rpc-name 'result (rpc-info-result-type info) value)
                     (typed->wire (rpc-info-result-type info) value)))))
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
