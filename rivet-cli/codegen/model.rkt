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
    (define get-rpcs (dynamic-require 'rivet/backend 'registered-rpcs))
    (define rpc-name (dynamic-require 'rivet/backend 'rpc-info-name))
    (define rpc-arg-names (dynamic-require 'rivet/backend 'rpc-info-arg-names))
    (define rpc-arg-types (dynamic-require 'rivet/backend 'rpc-info-arg-types))
    (define rpc-result-type (dynamic-require 'rivet/backend 'rpc-info-result-type))
    (define get-events (dynamic-require 'rivet/backend 'registered-events))
    (define event-name (dynamic-require 'rivet/backend 'event-info-name))
    (define event-type (dynamic-require 'rivet/backend 'event-info-type))
    (define get-states (dynamic-require 'rivet/backend 'registered-states))
    (define state-name (dynamic-require 'rivet/backend 'state-info-name))
    (define state-type (dynamic-require 'rivet/backend 'state-info-type))
    (define get-records (dynamic-require 'rivet/backend 'registered-records))
    (define record-name (dynamic-require 'rivet/backend 'record-info-name))
    (define record-field-names (dynamic-require 'rivet/backend 'record-info-field-names))
    (define record-field-types (dynamic-require 'rivet/backend 'record-info-field-types))
    (define get-enums (dynamic-require 'rivet/backend 'registered-enums))
    (define enum-name (dynamic-require 'rivet/backend 'enum-info-name))
    (define enum-cases (dynamic-require 'rivet/backend 'enum-info-cases))
    (values
     (for/list ([info (in-list (get-rpcs))])
       (schema-rpc (rpc-name info)
                   (rpc-arg-names info)
                   (rpc-arg-types info)
                   (rpc-result-type info)))
     (for/list ([info (in-list (get-events))])
       (schema-event (event-name info) (event-type info)))
     (for/list ([info (in-list (get-states))])
       (schema-state (state-name info) (state-type info)))
     (for/list ([info (in-list (get-records))])
       (schema-record (record-name info)
                      (record-field-names info)
                      (record-field-types info)))
     (for/list ([info (in-list (get-enums))])
       (schema-enum (enum-name info) (enum-cases info))))))

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
