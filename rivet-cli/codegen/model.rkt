#lang racket/base

(require racket/list
         "../project.rkt")

(provide (struct-out schema-rpc)
         (struct-out schema-event)
         (struct-out schema-state)
         (struct-out schema-record)
         (struct-out schema-enum)
         load-schema
         schema-name
         resolve-device-rpcs
         upper-first
         record-native-name)

(struct schema-rpc (name arg-names arg-types result-type) #:transparent)
(struct schema-event (name type) #:transparent)
(struct schema-state (name type) #:transparent)
(struct schema-record (name field-names field-types) #:transparent)
(struct schema-enum (name cases) #:transparent)

(define (load-schema backend)
  ;; Backends register declarations as a module side effect.  A fresh
  ;; namespace keeps separate projects from sharing a registry accidentally.
  (define ns (make-base-namespace))
  (parameterize ([current-namespace ns])
    (dynamic-require backend #f)
    (define get-schema (dynamic-require 'rivet/backend 'backend-schema))
    (define schema (get-schema))
    (values
     (for/list ([info (in-list (hash-ref schema 'rpcs))])
       (define arguments (hash-ref info 'arguments))
       (schema-rpc (hash-ref info 'name)
                   (map (lambda (argument) (hash-ref argument 'name)) arguments)
                   (map (lambda (argument) (hash-ref argument 'type)) arguments)
                   (hash-ref info 'result)))
     (for/list ([info (in-list (hash-ref schema 'events))])
       (schema-event (hash-ref info 'name) (hash-ref info 'type)))
     (for/list ([info (in-list (hash-ref schema 'states))])
       (schema-state (hash-ref info 'name) (hash-ref info 'type)))
     (for/list ([info (in-list (hash-ref schema 'records))])
       (define fields (hash-ref info 'fields))
       (schema-record (hash-ref info 'name)
                      (map (lambda (field) (hash-ref field 'name)) fields)
                      (map (lambda (field) (hash-ref field 'type)) fields)))
     (for/list ([info (in-list (hash-ref schema 'enums))])
       (schema-enum (hash-ref info 'name) (hash-ref info 'cases))))))

(define (schema-name value)
  (if (symbol? value) (symbol->string value) value))

(define (resolve-device-rpcs project rpcs [who 'generate-clients!])
  (define by-name
    (for/hash ([rpc (in-list rpcs)])
      (values (schema-rpc-name rpc) rpc)))
  (for/list ([name (in-list (project-device-rpcs project))])
    (hash-ref
     by-name
     name
     (lambda ()
       (raise-arguments-error
        who
        "device-rpcs contains an RPC that the backend does not declare"
        "RPC" name)))))

(define (upper-first value)
  (if (string=? value "")
      value
      (string-append (string-upcase (substring value 0 1))
                     (substring value 1))))

(define (record-native-name type id-proc)
  (upper-first (id-proc type)))
