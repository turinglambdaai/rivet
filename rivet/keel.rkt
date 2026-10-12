#lang racket/base

;; Keel is the transport-neutral application contract shared by Rivet and
;; Glaze. This module projects Rivet's immutable backend reflection snapshot
;; into that contract; it does not move RVT1 framing, native code generation,
;; or runtime ownership out of Rivet.

(require racket/match
         (prefix-in keel: keel)
         "backend.rkt")

(provide backend-schema->app-schema
         current-backend-app-schema)

(define (rivet-type->schema-type type)
  (match type
    ['Void keel:Unit]
    ['Bool keel:Bool]
    ['Int64 keel:Int64]
    ['String keel:String]
    ['Bytes keel:Bytes]
    ['Any keel:Value]
    [(list 'List element) (keel:list-type (rivet-type->schema-type element))]
    [(list 'Optional element) (keel:optional-type (rivet-type->schema-type element))]
    [(? symbol? name) (keel:reference-type name)]
    [_
     (raise-arguments-error 'backend-schema->app-schema
                            "unsupported Rivet schema type"
                            "type"
                            type)]))

(define (backend-schema->app-schema schema #:id id #:revision [revision 1])
  (unless (hash? schema)
    (raise-argument-error 'backend-schema->app-schema "hash?" schema))
  (define (entries key)
    (define value (hash-ref schema key))
    (unless (list? value)
      (raise-arguments-error 'backend-schema->app-schema
                             "backend schema section must be a list"
                             "section"
                             key
                             "value"
                             value))
    value)
  (keel:make-app-schema
   id
   revision
   #:records
   (for/list ([record (in-list (entries 'records))])
     (keel:schema-record (hash-ref record 'name)
                         (for/list ([field (in-list (hash-ref record 'fields))])
                           (keel:schema-field (hash-ref field 'name)
                                              (rivet-type->schema-type (hash-ref field 'type))))))
   #:enums (for/list ([enum (in-list (entries 'enums))])
             (keel:schema-enum (hash-ref enum 'name) (hash-ref enum 'cases)))
   #:commands (for/list ([rpc (in-list (entries 'rpcs))])
                (keel:schema-command
                 (hash-ref rpc 'name)
                 (for/list ([argument (in-list (hash-ref rpc 'arguments))])
                   (keel:schema-parameter (hash-ref argument 'name)
                                          (rivet-type->schema-type (hash-ref argument 'type))))
                 (rivet-type->schema-type (hash-ref rpc 'result))
                 ;; RVT1 v1 Error frames still carry a bounded diagnostic string rather
                 ;; than a typed application error. Keep this list honestly empty until
                 ;; Rivet adopts structured error codes at the schema/wire boundary.
                 '()))
   #:events (for/list ([event (in-list (entries 'events))])
              (keel:schema-event (hash-ref event 'name)
                                 (rivet-type->schema-type (hash-ref event 'type))))
   #:states (for/list ([state (in-list (entries 'states))])
              (keel:schema-state (hash-ref state 'name)
                                 (rivet-type->schema-type (hash-ref state 'type))))))

(define (current-backend-app-schema #:id id #:revision [revision 1])
  (backend-schema->app-schema (backend-schema) #:id id #:revision revision))
