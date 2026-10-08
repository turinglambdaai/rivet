#lang racket/base

(require racket/list
         racket/match
         "model.rkt")

(provide current-records
         current-enums
         current-swift-codable-types
         schema-record-for
         schema-enum-for
         device-codable-type?
         validate-device-rpcs!
         device-codable-named-types
         type-dependencies
         nested-types
         order-types
         all-types
         order-records
         type-key)

(define current-records (make-parameter '()))
(define current-enums (make-parameter '()))
(define current-swift-codable-types (make-parameter '()))

(define (schema-record-for type)
  (and (symbol? type)
       (findf (lambda (record) (eq? (schema-record-name record) type))
              (current-records))))

(define (schema-enum-for type)
  (and (symbol? type)
       (findf (lambda (enum) (eq? (schema-enum-name enum) type))
              (current-enums))))

(define (device-codable-type? type #:void-result? [void-result? #f])
  (match type
    [(or 'String 'Int64 'Bool 'Bytes) #t]
    ['Void void-result?]
    ['Any #f]
    [(list (or 'List 'Optional) inner)
     (device-codable-type? inner)]
    [_
     (define record (schema-record-for type))
     (cond
       [record
        (andmap device-codable-type? (schema-record-field-types record))]
       [(schema-enum-for type) #t]
       [else #f])]))

(define (validate-device-rpcs! rpcs)
  (for ([rpc (in-list rpcs)])
    (for ([name (in-list (schema-rpc-arg-names rpc))]
          [type (in-list (schema-rpc-arg-types rpc))])
      (unless (device-codable-type? type)
        (raise-arguments-error
         'generate-clients!
         "device RPC argument is not representable by the Codable companion channel"
         "RPC" (schema-rpc-name rpc)
         "argument" name
         "type" type)))
    (unless (device-codable-type? (schema-rpc-result-type rpc) #:void-result? #t)
      (raise-arguments-error
       'generate-clients!
       "device RPC result is not representable by the Codable companion channel"
       "RPC" (schema-rpc-name rpc)
       "type" (schema-rpc-result-type rpc)))))

(define (device-codable-named-types rpcs)
  (remove-duplicates
   (filter
    (lambda (type) (or (schema-record-for type) (schema-enum-for type)))
    (append*
     (for/list ([rpc (in-list rpcs)])
       (append*
        (map nested-types
             (append (schema-rpc-arg-types rpc)
                     (list (schema-rpc-result-type rpc))))))))
   eq?))

(define (type-dependencies type)
  (match type
    [(list (or 'List 'Optional) inner) (list inner)]
    [_
     (define record (schema-record-for type))
     (if record (schema-record-field-types record) '())]))

(define (nested-types type)
  (cons type
        (append*
         (for/list ([dependency (in-list (type-dependencies type))])
           (nested-types dependency)))))

(define (order-types types)
  (define seen (make-hash))
  (define active (make-hash))
  (define result '())
  (define (visit type)
    (unless (hash-ref seen type #f)
      (when (hash-ref active type #f)
        (error 'generate-clients! "recursive Rivet Record/type dependency: ~e" type))
      (hash-set! active type #t)
      (for ([dependency (in-list (type-dependencies type))])
        (visit dependency))
      (hash-remove! active type)
      (hash-set! seen type #t)
      (set! result (cons type result))))
  (for ([type (in-list types)]) (visit type))
  (reverse result))

(define (all-types rpcs events states records enums)
  (define raw
    (append
     (append*
      (for/list ([info (in-list rpcs)])
        (append*
         (map nested-types
              (append (schema-rpc-arg-types info)
                      (list (schema-rpc-result-type info)))))))
     (append*
      (for/list ([event (in-list events)])
        (nested-types (schema-event-type event))))
     (append*
      (for/list ([state (in-list states)])
        (nested-types (schema-state-type state))))
     (append*
      (for/list ([record (in-list records)])
        (nested-types (schema-record-name record))))
     (for/list ([enum (in-list enums)])
       (schema-enum-name enum))))
  (order-types (remove-duplicates raw equal?)))

(define (order-records records)
  (define ordered-types
    (order-types (map schema-record-name records)))
  (filter-map schema-record-for ordered-types))

(define (type-key type)
  (regexp-replace* #px"[^A-Za-z0-9]+" (format "~s" type) "_"))
