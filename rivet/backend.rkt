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
(struct pending-request (custodian terminal-owned cancel-deferred cancel-requested) #:mutable)

(define registry (make-hash))
(define event-registry (make-hash))
(define state-registry (make-hash))
(define current-event-emitter (make-parameter #f))
;; Request workers replace this identity wrapper with a cancellation barrier.
;; Keeping it private lets state-set! preserve the same behavior outside serve.
(define current-state-commit-guard (make-parameter (lambda (thunk) (thunk))))

;; `state-info` is public through struct-out, so keep update-order bookkeeping
;; private instead of adding a field that would break constructor/pattern source
;; compatibility. Weak identity keys also avoid retaining externally constructed
;; State values after the application releases them.
(define state-update-locks (make-weak-hasheq))
(define state-update-locks-lock (make-semaphore 1))

(define (state-update-lock state)
  (call-with-semaphore
   state-update-locks-lock
   (lambda ()
     (or (hash-ref state-update-locks state #f)
         (let ([lock (make-semaphore 1)])
           (hash-set! state-update-locks state lock)
           lock)))))

;; RPC/State lookup names arrive as untrusted wire Strings and are converted to
;; interned Racket symbols for registry lookup. Bound API identifiers before
;; that conversion so a tiny request cannot force an arbitrarily large symbol
;; allocation. Apply the same limit at declaration time so registered APIs are
;; always reachable through the wire protocol.
(define max-api-name-bytes 1024)

(define (check-api-name-length! who kind name)
  (unless (string? name)
    (raise-argument-error who "string?" name))
  (define length (string-utf-8-length name))
  (when (> length max-api-name-bytes)
    (raise-arguments-error who
                           (format "~a name exceeds Rivet API limit" kind)
                           "length bytes" length
                           "maximum bytes" max-api-name-bytes)))

(define (wire-api-name->symbol who kind name)
  (check-api-name-length! who kind name)
  (string->symbol name))

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

;; Typed validation must not do more structural work than the protocol encoder
;; it protects. Track the same total value-node and List-nesting budgets while
;; walking only the structure required by the declared type. `Any` is accepted
;; without recursively inspecting its contents; encode-value remains the final
;; authority for arbitrary Any subtrees.
(define (value-validation-result type value)
  (define remaining-nodes max-value-nodes)

  (define (consume-node!)
    (cond
      [(zero? remaining-nodes) #f]
      [else
       (set! remaining-nodes (sub1 remaining-nodes))
       #t]))

  (define (matches type value depth)
    ;; Optional is a schema wrapper, not an extra wire node. A present Optional
    ;; delegates node accounting to its inner type; absent Optional uses the one
    ;; Null node that is actually encoded.
    (match type
      [(list 'Optional inner)
       (if (void? value)
           (if (consume-node!) 'valid 'node-limit)
           (matches inner value depth))]
      [_
       (cond
         [(not (consume-node!)) 'node-limit]
         [else
          (case type
            [(String) (if (string? value) 'valid 'mismatch)]
            [(Int64)
             (if (and (exact-integer? value)
                      (<= (- (expt 2 63)) value (sub1 (expt 2 63))))
                 'valid
                 'mismatch)]
            [(Bool) (if (boolean? value) 'valid 'mismatch)]
            [(Bytes) (if (bytes? value) 'valid 'mismatch)]
            [(Void) (if (void? value) 'valid 'mismatch)]
            [(Any) 'valid]
            [else
             (match type
               [(list 'List inner)
                (cond
                  [(>= depth max-value-depth) 'depth-limit]
                  [else
                   ;; Avoid `list?` + `andmap`: both can traverse an arbitrarily
                   ;; large application List before the RVT1 budget is applied.
                   ;; Walking cdrs here terminates as soon as an element consumes
                   ;; the last available protocol node.
                   (let loop ([rest value])
                     (cond
                       [(null? rest) 'valid]
                       [(not (pair? rest)) 'mismatch]
                       [else
                        (define item-result
                          (matches inner (car rest) (add1 depth)))
                        (if (eq? item-result 'valid)
                            (loop (cdr rest))
                            item-result)]))])]
               [_ 'mismatch])])])]))

  (matches type value 0))

(define (safe-value-kind value)
  ;; Diagnostics must never print or fully traverse an arbitrary application
  ;; value. Pair/null classification is O(1); proving proper-List-ness belongs
  ;; to bounded typed validation or the protocol encoder, not error reporting.
  (cond
    [(void? value) 'Void]
    [(string? value) 'String]
    [(boolean? value) 'Bool]
    [(bytes? value) 'Bytes]
    [(and (exact-integer? value)
          (<= (- (expt 2 63)) value (sub1 (expt 2 63))))
     'Int64]
    [(exact-integer? value) 'Integer]
    [(or (null? value) (pair? value)) 'ListLike]
    [else 'Unsupported]))

(define (validate-value who label type value)
  (case (value-validation-result type value)
    [(valid) (void)]
    [(node-limit)
     (raise-arguments-error who
                            "value node count exceeds Rivet protocol limit"
                            "position" label
                            "maximum nodes" max-value-nodes)]
    [(depth-limit)
     (raise-arguments-error who
                            "value nesting exceeds Rivet protocol limit"
                            "position" label
                            "maximum depth" max-value-depth)]
    [else
     (raise-arguments-error who
                            "value does not match declared Rivet type"
                            "position" label
                            "expected" type
                            "received" (safe-value-kind value))]))

(define (register-rpc! name arg-names arg-types result-type proc)
  (check-api-name-length! 'define-rpc "RPC" (symbol->string name))
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
  (check-api-name-length! 'define-event "Event" (symbol->string name))
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

(define (state-event-value name value)
  (list (symbol->string name) value))

(define (encode-state-event-payload event-value)
  (encode-value (list "$state" event-value)))

(define (register-state! name type initial)
  (check-api-name-length! 'define-state "State" (symbol->string name))
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
  ;; A State is a wire-visible value even before a server starts. Validate the
  ;; complete reserved Event shape before storing the initial value so every
  ;; registered State can later be synchronized to native clients.
  (encode-state-event-payload (state-event-value name initial))
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
  (define name (state-info-name state))
  (validate-value 'state-set! name (state-info-type state) value)
  ;; Pre-encode the exact Event before committing the cell. If the value is
  ;; type-correct but violates RVT1 byte/node/depth limits, state-set! fails
  ;; without mutating shared state or emitting a partial update.
  (define event-value (state-event-value name value))
  (define event-payload (encode-state-event-payload event-value))
  (define emitter (current-event-emitter))
  (define update-lock (state-update-lock state))
  ;; Waiting for an earlier update-order lock is still safely cancellable: no
  ;; State side effect has happened yet. Once this setter owns the order lock,
  ;; a request-local commit guard defers cancellation across the short cell
  ;; commit plus potentially backpressured Event admission. This guarantees that
  ;; every State value that becomes visible in Racket has a corresponding
  ;; reserved Event accepted for native delivery.
  (call-with-semaphore
   update-lock
   (lambda ()
     ((current-state-commit-guard)
      (lambda ()
        (call-with-semaphore
         (state-info-lock state)
         (lambda () (set-box! (state-info-cell state) value)))
        (when emitter
          (emitter "$state" event-value event-payload))))))
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
     (values (wire-api-name->symbol 'serve "RPC" name) args)]
    [_
     (error 'serve "invalid RPC request payload shape")]))

;; Error frames are diagnostic terminal messages, not bulk payloads. Keep them
;; bounded well below the RVT1 64 MiB value limit so an application exception
;; cannot consume large amounts of memory merely while reporting failure.
(define max-error-message-chars 4096)
(define error-truncation-suffix "... [truncated]")

(define (bounded-error-message message)
  (unless (string? message)
    (raise-argument-error 'bounded-error-message "string?" message))
  (if (<= (string-length message) max-error-message-chars)
      message
      (string-append
       (substring message
                  0
                  (- max-error-message-chars
                     (string-length error-truncation-suffix)))
       error-truncation-suffix)))

(define (error-message->payload message)
  ;; The fallback is intentionally tiny. It protects terminal-response
  ;; delivery if future changes make normal diagnostic encoding fail for a
  ;; reason other than message length.
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (encode-value "Rivet request failed"))])
    (encode-value (bounded-error-message message))))

(define (raised->payload raised)
  ;; Racket permits `(raise value)` for any value, not only the `exn:fail?`
  ;; hierarchy. Preserve normal exception messages, but never format/echo an
  ;; arbitrary raised object: a custom writer or huge object could make error
  ;; reporting itself fail or consume unbounded work.
  (error-message->payload
   (if (exn? raised)
       (exn-message raised)
       "Rivet request raised a non-exception value")))

(define (lookup-state name)
  (define key (wire-api-name->symbol '$state "State" name))
  (hash-ref state-registry
            key
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

(define (serve in out
               #:max-pending-requests [max-pending-requests 1024]
               #:max-outgoing-frames [max-outgoing-frames 64])
  (unless (input-port? in)
    (raise-argument-error 'serve "input-port?" in))
  (unless (output-port? out)
    (raise-argument-error 'serve "output-port?" out))
  (unless (and (exact-integer? max-pending-requests)
               (positive? max-pending-requests))
    (raise-argument-error 'serve "positive exact integer" max-pending-requests))
  (unless (and (exact-integer? max-outgoing-frames)
               (positive? max-outgoing-frames))
    (raise-argument-error 'serve "positive exact integer" max-outgoing-frames))

  ;; Keep application/request threads and the writer in separate custodians.
  ;; Graceful shutdown can stop every producer first, drain already accepted
  ;; frames, and only then stop the writer. An abort can still tear down the
  ;; whole server domain at once.
  (define server-custodian (make-custodian))
  (define runtime-custodian (make-custodian server-custodian))
  (define writer-custodian (make-custodian server-custodian))
  (define responses (make-async-channel max-outgoing-frames))
  (define pending (make-hash))
  (define pending-lock (make-semaphore 1))
  (define event-id-lock (make-semaphore 1))
  (define writer-error (box #f))
  (define reader-error (box #f))
  (define stopped? #f)
  (define next-event-id 1)

  (define writer
    (parameterize ([current-custodian writer-custodian])
      (thread
       (lambda ()
         (with-handlers ([exn?
                          (lambda (e)
                            (set-box! writer-error e))])
           (let loop ()
             (define response (async-channel-get responses))
             (unless (eq? response 'stop)
               (write-frame response out)
               (loop))))))))
  (define writer-dead-evt (thread-dead-evt writer))

  (define (raise-writer-failure!)
    (define failure (unbox writer-error))
    (if failure
        (raise failure)
        (error 'serve "response writer terminated unexpectedly")))

  (define (send! value)
    ;; A bounded channel applies output backpressure. Waiting producers also
    ;; observe writer death, so a broken transport cannot strand request/Event
    ;; threads forever behind a full queue.
    (define outcome
      (sync
       (handle-evt (async-channel-put-evt responses value)
                   (lambda (_) 'sent))
       (handle-evt writer-dead-evt
                   (lambda (_) 'writer-dead))))
    (when (eq? outcome 'writer-dead)
      (raise-writer-failure!))
    (void))

  (define (request-id-pending? id)
    (call-with-semaphore
     pending-lock
     (lambda () (hash-has-key? pending id))))

  (define (admit-request! id custodian)
    (call-with-semaphore
     pending-lock
     (lambda ()
       (cond
         [(hash-has-key? pending id) 'duplicate]
         [(>= (hash-count pending) max-pending-requests) 'full]
         [else
          (hash-set! pending id (pending-request custodian #f #f #f))
          'admitted]))))

  (define (claim-pending! id)
    ;; Completion/error/cancellation claim terminal ownership without removing
    ;; the entry yet. The request continues to occupy its pending slot while a
    ;; terminal frame is waiting for output capacity, so backpressure cannot be
    ;; bypassed by admitting an unbounded stream of newly completed requests.
    (call-with-semaphore
     pending-lock
     (lambda ()
       (define request (hash-ref pending id #f))
       (cond
         [(and request
               (not (pending-request-terminal-owned request)))
          (set-pending-request-terminal-owned! request #t)
          request]
         [else #f]))))

  (define (cancel-action! id)
    ;; State commits can briefly defer cancellation after the cell becomes
    ;; visible and until its reserved Event is accepted by the output queue.
    ;; Keep the pending slot occupied during that interval so cancellation
    ;; cannot bypass either correlation ownership or the concurrency limit.
    (call-with-semaphore
     pending-lock
     (lambda ()
       (define request (hash-ref pending id #f))
       (cond
         [(or (not request)
              (pending-request-terminal-owned request))
          #f]
         [(pending-request-cancel-deferred request)
          (set-pending-request-cancel-requested! request #t)
          'deferred]
         [else
          (set-pending-request-terminal-owned! request #t)
          request]))))

  (define (begin-state-commit! id)
    (call-with-semaphore
     pending-lock
     (lambda ()
       (define request (hash-ref pending id #f))
       (cond
         [(not request) 'untracked]
         [(pending-request-terminal-owned request) 'terminal]
         [else
          (set-pending-request-cancel-deferred! request #t)
          request]))))

  (define (end-state-commit! id request)
    ;; Clear the barrier and atomically convert any deferred Cancel into terminal
    ;; ownership before another Cancel or normal Response can race in.
    (call-with-semaphore
     pending-lock
     (lambda ()
       (define current (hash-ref pending id #f))
       (cond
         [(not (eq? current request)) #f]
         [else
          (set-pending-request-cancel-deferred! request #f)
          (cond
            [(and (pending-request-cancel-requested request)
                  (not (pending-request-terminal-owned request)))
             (set-pending-request-terminal-owned! request #t)
             request]
            [else #f])]))))

  (define (release-pending! id request)
    (call-with-semaphore
     pending-lock
     (lambda ()
       (when (eq? (hash-ref pending id #f) request)
         (hash-remove! pending id)))))

  (define (take-all-pending!)
    (call-with-semaphore
     pending-lock
     (lambda ()
       (define requests (hash-values pending))
       (hash-clear! pending)
       (map pending-request-custodian requests))))

  (define (send-claimed! id request response)
    ;; Always release the pending slot after the send attempt, including an
    ;; asynchronous break or writer failure. On transport failure the outer
    ;; server supervisor tears down the remaining runtime immediately.
    (dynamic-wind
      void
      (lambda () (send! response))
      (lambda () (release-pending! id request))))

  (define (finish-deferred-cancel! id request)
    ;; The State Event has already been admitted. Queue the one terminal
    ;; cancelled Error, then tear down this request custodian so application
    ;; code cannot keep running after a cancellation that was deferred solely to
    ;; preserve State/native consistency.
    (send-claimed!
     id
     request
     (frame message:error id (error-message->payload "request cancelled")))
    (custodian-shutdown-all (pending-request-custodian request))
    ;; `custodian-shutdown-all` normally terminates the current worker because
    ;; it is managed by this request custodian. Keep a defensive local fallback
    ;; so the cancelled request cannot resume if that assumption ever changes.
    (kill-thread (current-thread)))

  (define (with-state-commit-barrier id thunk)
    (define request (begin-state-commit! id))
    (cond
      [(eq? request 'untracked)
       ;; A child thread may outlive an already completed request. There is no
       ;; pending cancellation owner left, so preserve ordinary state-set!
       ;; behavior instead of inventing a new failure mode.
       (thunk)]
      [(eq? request 'terminal)
       ;; Cancellation/completion already owns the terminal outcome. Do not
       ;; begin a fresh State side effect in the tiny window before this worker
       ;; is stopped.
       (error 'state-set! "request is no longer active")]
      [else
       (define completed? #f)
       (define raised-value #f)
       (with-handlers ([(lambda (_) #t)
                        (lambda (raised)
                          (set! raised-value raised)
                          (void))])
         (thunk)
         (set! completed? #t))
       (define cancelled-request (end-state-commit! id request))
       (cond
         [cancelled-request
          (finish-deferred-cancel! id cancelled-request)]
         [completed? (void)]
         [else (raise raised-value)])]))

  (define (finish! id type value)
    ;; Encode while the request is still claimable. If encoding fails, the
    ;; worker's handler can claim the same request and send Error. Cancellation
    ;; may still win during encoding; after a completion claim succeeds, the
    ;; pending slot remains occupied until its terminal frame enters the output
    ;; queue.
    (define payload (encode-value value))
    (define request (claim-pending! id))
    (when request
      (send-claimed! id request (frame type id payload))))

  (define (allocate-event-id!)
    (call-with-semaphore
     event-id-lock
     (lambda ()
       (define id next-event-id)
       (set! next-event-id (add1 next-event-id))
       id)))

  (define (emit! name value [encoded-payload #f])
    ;; Encode before allocating an Event id so a rejected Event does not create
    ;; a gap. State updates can supply a pre-encoded payload that was validated
    ;; before the State cell was committed.
    (define payload
      (or encoded-payload
          (encode-value (list name value))))
    (send! (frame message:event
                  (allocate-event-id!)
                  payload)))

  (define (reject-request! id message)
    (send! (frame message:error id (error-message->payload message))))

  (define (request-error! id raised)
    ;; Build the guaranteed-small Error payload before claiming terminal
    ;; ownership. A claimed request stays pending until the Error is admitted to
    ;; the bounded output queue. Catching arbitrary raised values here is
    ;; essential because a dead worker must not strand its pending entry.
    (define payload (raised->payload raised))
    (define request (claim-pending! id))
    (when request
      (send-claimed! id request (frame message:error id payload))))

  (define (run-request! id rpc-name args internal-state-request? info)
    (with-handlers ([(lambda (_) #t)
                     (lambda (raised)
                       (request-error! id raised))])
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
                (validate-value rpc-name
                                'result
                                (rpc-info-result-type info)
                                value)
                value))))
      (finish! id message:response result)))

  (define (start-request! f)
    (define id (frame-id f))
    ;; A request id is the only correlation key available to native clients.
    ;; While the first request still owns that id, a second Request cannot be
    ;; rejected with another terminal frame without stealing the original
    ;; caller's continuation. First request wins: ignore duplicates before even
    ;; parsing their payload. The id becomes reusable after the original entry
    ;; is released from `pending`.
    (unless (request-id-pending? id)
      ;; Bad application requests must fail that request rather than tear down
      ;; the entire embedded runtime. The native client generated by Rivet
      ;; should not produce these frames, but keeping the server alive makes
      ;; failures local.
      (with-handlers ((exn:fail?
                       (lambda (e)
                         (reject-request! id (exn-message e)))))
        (define-values (rpc-name args) (request->call (frame-payload f)))
        (define internal-state-request?
          (memq rpc-name '($state/get $state/set)))
        (define info
          (and (not internal-state-request?)
               (hash-ref registry rpc-name
                         (lambda ()
                           (error 'serve "unknown RPC: ~a" rpc-name)))))
        (define request-custodian (make-custodian runtime-custodian))
        (define admission (admit-request! id request-custodian))
        (cond
          ((eq? admission 'duplicate)
           ;; Defensive fallback if request admission ever becomes concurrent.
           ;; Never emit a second terminal frame for an already-pending id.
           (custodian-shutdown-all request-custodian))
          ((eq? admission 'full)
           (custodian-shutdown-all request-custodian)
           (reject-request!
            id
            (format "too many pending requests (limit ~a)" max-pending-requests)))
          (else
           (parameterize ([current-custodian request-custodian]
                          [current-state-commit-guard
                           (lambda (thunk)
                             (with-state-commit-barrier id thunk))])
             (thread
              (lambda ()
                (run-request! id
                              rpc-name
                              args
                              internal-state-request?
                              info)))))))))

  (define (cancel! id)
    (define action (cancel-action! id))
    (when (pending-request? action)
      (custodian-shutdown-all (pending-request-custodian action))
      (send-claimed!
       id
       action
       (frame message:error id (error-message->payload "request cancelled")))))

  (define (dispatch! f)
    (case (frame-type f)
      [(2) (start-request! f)]
      [(6) (cancel! (frame-id f))]
      [(7) (set! stopped? #t)]
      [else
       ;; An inbound Hello/Response/Error/Event is invalid for the backend, but
       ;; replying with Error using an id that already belongs to a pending
       ;; Request would steal that request's native continuation. Preserve the
       ;; same first-request-wins rule used for duplicate Requests: conflicting
       ;; illegal frames are ignored, while unowned ids keep the existing
       ;; request-local diagnostic behavior.
       (unless (request-id-pending? (frame-id f))
         (send! (frame message:error
                       (frame-id f)
                       (error-message->payload
                        (format "unsupported message type: ~a"
                                (frame-type f))))))]))

  (define reader
    (parameterize ([current-custodian runtime-custodian])
      (thread
       (lambda ()
         (with-handlers ([exn?
                          (lambda (e)
                            (set-box! reader-error e))])
           (parameterize ([current-event-emitter emit!]
                          [exit-handler
                           (lambda (value)
                             (if (exn? value)
                                 (raise value)
                                 (error 'rivet/backend
                                        "backend requested exit with non-exception value")))])
             (send! (frame message:hello 0
                           (encode-value (list "rivet" protocol-version))))
             (let loop ()
               (unless stopped?
                 (define f (read-frame in))
                 (if (eof-object? f)
                     (set! stopped? #t)
                     (begin
                       (dispatch! f)
                       (loop)))))))))))
  (define reader-dead-evt (thread-dead-evt reader))

  (define cleanup-done? #f)

  (define (shutdown-runtime!)
    (for ([cust (in-list (take-all-pending!))])
      (custodian-shutdown-all cust))
    ;; Also terminate child threads spawned by completed RPCs, which are no
    ;; longer represented in the pending table but still belong to the runtime
    ;; custodian and could otherwise emit after the writer stop marker.
    (custodian-shutdown-all runtime-custodian))

  (define (abort-server!)
    (unless cleanup-done?
      (for ([cust (in-list (take-all-pending!))])
        (custodian-shutdown-all cust))
      (custodian-shutdown-all server-custodian)
      (set! cleanup-done? #t)))

  (define (finish-after-reader!)
    (shutdown-runtime!)
    (define writer-problem #f)
    (cond
      [(sync/timeout 0 writer-dead-evt)
       (set! writer-problem
             (or (unbox writer-error) 'unexpected-writer-exit))]
      [else
       (with-handlers ([exn?
                        (lambda (e)
                          (set! writer-problem e))])
         ;; No producers remain after shutdown-runtime!, so this marker is
         ;; ordered after every frame that was successfully admitted.
         (send! 'stop)
         (sync writer-dead-evt)
         (when (unbox writer-error)
           (set! writer-problem (unbox writer-error))))])
    (custodian-shutdown-all writer-custodian)
    (custodian-shutdown-all server-custodian)
    (set! cleanup-done? #t)
    (define reader-problem (unbox reader-error))
    (cond
      [(exn? writer-problem) (raise writer-problem)]
      [writer-problem
       (error 'serve "response writer terminated unexpectedly")]
      [reader-problem (raise reader-problem)]
      [else (void)]))

  (dynamic-wind
    void
    (lambda ()
      (define first-exit
        (sync
         (handle-evt reader-dead-evt (lambda (_) 'reader))
         (handle-evt writer-dead-evt (lambda (_) 'writer))))
      (cond
        [(eq? first-exit 'writer)
         (define failure (unbox writer-error))
         (abort-server!)
         (if failure
             (raise failure)
             (error 'serve "response writer terminated unexpectedly"))]
        [else
         (finish-after-reader!)]))
    (lambda ()
      (unless cleanup-done?
        (abort-server!))))

  (void))

(define (serve-fds in-fd out-fd
                   #:max-pending-requests [max-pending-requests 1024]
                   #:max-outgoing-frames [max-outgoing-frames 64])
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
        (serve in
               out
               #:max-pending-requests max-pending-requests
               #:max-outgoing-frames max-outgoing-frames)))
    (lambda ()
      (unless (port-closed? in) (close-input-port in))
      (unless (port-closed? out) (close-output-port out)))))