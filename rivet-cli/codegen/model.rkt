#lang racket/base

(require racket/list
         (prefix-in keel: keel)
         "../project.rkt")

(provide schema-rpc?
         schema-rpc-name
         schema-rpc-arg-names
         schema-rpc-arg-types
         schema-rpc-result-type
         schema-event?
         schema-event-name
         schema-event-type
         schema-state?
         schema-state-name
         schema-state-type
         schema-record?
         schema-record-name
         schema-record-field-names
         schema-record-field-types
         schema-enum?
         schema-enum-name
         schema-enum-cases
         load-schema
         schema-name
         resolve-device-rpcs
         upper-first
         record-native-name)

(define schema-rpc? keel:schema-command?)
(define schema-event? keel:schema-event?)
(define schema-state? keel:schema-state?)
(define schema-record? keel:schema-record?)
(define schema-enum? keel:schema-enum?)
(define-namespace-anchor model-namespace-anchor)

;; Native generators still target RVT1's deliberately smaller type system.
;; Keep that transport mapping in one adapter while Keel remains the canonical
;; in-memory schema. Unsupported Keel types fail here instead of being silently
;; approximated by a generator.
(define (keel-type->rvt1-type type)
  (cond
    [(keel:scalar-type? type)
     (case (keel:scalar-type-name type)
       [(Bool Int64 String Bytes) (keel:scalar-type-name type)]
       [(Unit) 'Void]
       [(Value) 'Any]
       [else
        (raise-arguments-error 'load-schema
                               "Keel type is not supported by RVT1"
                               "type" type)])]
    [(keel:list-type? type)
     (list 'List (keel-type->rvt1-type (keel:list-type-element type)))]
    [(keel:optional-type? type)
     (list 'Optional
           (keel-type->rvt1-type (keel:optional-type-element type)))]
    [(keel:reference-type? type)
     (string->symbol (keel:reference-type-name type))]
    [else
     (raise-arguments-error 'load-schema
                            "Keel type is not supported by RVT1"
                            "type" type)]))

(define (schema-rpc-name rpc)
  (string->symbol (keel:schema-command-name rpc)))

(define (schema-rpc-arg-names rpc)
  (for/list ([parameter (in-list (keel:schema-command-parameters rpc))])
    (string->symbol (keel:schema-parameter-name parameter))))

(define (schema-rpc-arg-types rpc)
  (for/list ([parameter (in-list (keel:schema-command-parameters rpc))])
    (keel-type->rvt1-type (keel:schema-parameter-type parameter))))

(define (schema-rpc-result-type rpc)
  (keel-type->rvt1-type (keel:schema-command-result rpc)))

(define (schema-event-name event)
  (string->symbol (keel:schema-event-name event)))

(define (schema-event-type event)
  (keel-type->rvt1-type (keel:schema-event-type event)))

(define (schema-state-name state)
  (string->symbol (keel:schema-state-name state)))

(define (schema-state-type state)
  (keel-type->rvt1-type (keel:schema-state-type state)))

(define (schema-record-name record)
  (string->symbol (keel:schema-record-name record)))

(define (schema-record-field-names record)
  (for/list ([field (in-list (keel:schema-record-fields record))])
    (string->symbol (keel:schema-field-name field))))

(define (schema-record-field-types record)
  (for/list ([field (in-list (keel:schema-record-fields record))])
    (keel-type->rvt1-type (keel:schema-field-type field))))

(define (schema-enum-name enum)
  (string->symbol (keel:schema-enum-name enum)))

(define (schema-enum-cases enum)
  (map string->symbol (keel:schema-enum-cases enum)))

(define (load-schema backend #:id [id "rivet.codegen"])
  ;; Backends register declarations as a module side effect.  A fresh
  ;; namespace keeps separate projects from sharing a registry accidentally.
  ;; Attach Keel from the caller namespace so the isolated Rivet instance
  ;; returns canonical structs recognized by these accessors; only Rivet's
  ;; mutable backend registry must be instantiated per project.
  (define ns (make-base-namespace))
  (namespace-attach-module
   (namespace-anchor->namespace model-namespace-anchor)
   'keel
   ns)
  (parameterize ([current-namespace ns])
    (dynamic-require backend #f)
    (define current-schema
      (dynamic-require 'rivet/keel 'current-backend-app-schema))
    (define schema (current-schema #:id id))
    (values (keel:app-schema-commands schema)
            (keel:app-schema-events schema)
            (keel:app-schema-states schema)
            (keel:app-schema-records schema)
            (keel:app-schema-enums schema))))

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
