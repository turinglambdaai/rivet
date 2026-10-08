#lang racket/base

(require json
         racket/file
         racket/list
         racket/match
         "../project.rkt"
         "model.rkt"
         "type-graph.rkt")

(provide schema-snapshot
         write-schema-snapshot!
         check-schema-compatibility!)

(define schema-snapshot-format "rivet-schema")
(define schema-snapshot-version 1)
(define scalar-types '(String Int64 Bool Bytes Void Any))

(define (type->snapshot type)
  (match type
    [(? symbol?)
     (hash 'kind (if (member type scalar-types) "scalar" "record")
           'name (symbol->string type))]
    [(list 'List element)
     (hash 'kind "list" 'element (type->snapshot element))]
    [(list 'Optional element)
     (hash 'kind "optional" 'element (type->snapshot element))]
    [_
     (error 'schema-snapshot "unsupported schema type: ~e" type)]))

(define (sort-schema entries name-of)
  (sort entries string<? #:key (lambda (entry) (schema-name (name-of entry)))))

(define (schema-snapshot project)
  (define backend (project-path project (project-ref project 'backend)))
  (define-values (rpcs events states records enums) (load-schema backend))
  (define device-rpcs (resolve-device-rpcs project rpcs 'schema-snapshot))
  (parameterize ([current-records records]
                 [current-enums enums])
    (void (all-types rpcs events states records enums))
    (validate-device-rpcs! device-rpcs))
  (hash
   'format schema-snapshot-format
   'format-version schema-snapshot-version
   'rvt-protocol (project-ref project 'protocol)
   'device-rpcs
   (for/list ([rpc (in-list (sort-schema device-rpcs schema-rpc-name))])
     (hash 'name (schema-name (schema-rpc-name rpc))))
   'records
   (for/list ([record (in-list (sort-schema records schema-record-name))])
     (hash
      'name (schema-name (schema-record-name record))
      ;; Record field order is wire-significant and must not be sorted.
      'fields
      (for/list ([name (in-list (schema-record-field-names record))]
                 [type (in-list (schema-record-field-types record))])
        (hash 'name (schema-name name) 'type (type->snapshot type)))))
   'enums
   (for/list ([enum (in-list (sort-schema enums schema-enum-name))])
     (hash 'name (schema-name (schema-enum-name enum))
           'cases (map schema-name (schema-enum-cases enum))))
   'rpcs
   (for/list ([rpc (in-list (sort-schema rpcs schema-rpc-name))])
     (hash
      'name (schema-name (schema-rpc-name rpc))
      'arguments
      (for/list ([name (in-list (schema-rpc-arg-names rpc))]
                 [type (in-list (schema-rpc-arg-types rpc))])
        (hash 'name (schema-name name) 'type (type->snapshot type)))
      'result (type->snapshot (schema-rpc-result-type rpc))))
   'events
   (for/list ([event (in-list (sort-schema events schema-event-name))])
     (hash 'name (schema-name (schema-event-name event))
           'type (type->snapshot (schema-event-type event))))
   'states
   (for/list ([state (in-list (sort-schema states schema-state-name))])
     (hash 'name (schema-name (schema-state-name state))
           'type (type->snapshot (schema-state-type state))))))

(define (write-schema-snapshot! project output-path)
  (define destination (path->complete-path output-path))
  (make-parent-directory* destination)
  (call-with-output-file destination #:exists 'truncate/replace
    (lambda (out)
      (write-json (schema-snapshot project) out #:indent 2)
      (newline out)))
  destination)

(define (snapshot-section snapshot key)
  ;; `enums` and `device-rpcs` were added additively to snapshot format v1.
  ;; Older v1 baselines omit them and therefore mean empty sets.
  (define value
    (hash-ref snapshot key (if (memq key '(enums device-rpcs)) '() #f)))
  (unless (list? value)
    (error 'check-schema-compatibility! "schema snapshot field ~a must be an array" key))
  value)

(define (validate-snapshot! snapshot label)
  (unless (hash? snapshot)
    (error 'check-schema-compatibility! "~a schema snapshot must be a JSON object" label))
  (unless (equal? (hash-ref snapshot 'format #f) schema-snapshot-format)
    (error 'check-schema-compatibility!
           "~a schema snapshot has unsupported format ~e"
           label
           (hash-ref snapshot 'format #f)))
  (unless (equal? (hash-ref snapshot 'format-version #f) schema-snapshot-version)
    (error 'check-schema-compatibility!
           "~a schema snapshot has unsupported format version ~e"
           label
           (hash-ref snapshot 'format-version #f)))
  (unless (hash-has-key? snapshot 'rvt-protocol)
    (error 'check-schema-compatibility! "~a schema snapshot has no rvt-protocol" label))
  (for ([section (in-list '(records enums rpcs events states device-rpcs))])
    (for ([entry (in-list (snapshot-section snapshot section))])
      (unless (and (hash? entry) (string? (hash-ref entry 'name #f)))
        (error 'check-schema-compatibility!
               "~a schema snapshot contains an invalid ~a entry"
               label
               section)))))

(define (index-section entries section label)
  (for/fold ([result (hash)]) ([entry (in-list entries)])
    (define name (hash-ref entry 'name))
    (when (hash-has-key? result name)
      (error 'check-schema-compatibility!
             "~a schema snapshot contains duplicate ~a name ~a"
             label section name))
    (hash-set result name entry)))

(define (change section name kind message [before #f] [after #f])
  (define base (hash 'section (symbol->string section)
                     'name name
                     'change kind
                     'message message))
  (define with-before (if before (hash-set base 'before before) base))
  (if after (hash-set with-before 'after after) with-before))

;; JSON readers are free to choose a different hash key comparator from the
;; immutable hashes used to construct the live snapshot. Compare JSON values
;; structurally so a snapshot remains portable across Racket implementations.
(define (json-equivalent? left right)
  (cond
    [(and (hash? left) (hash? right))
     (and (= (hash-count left) (hash-count right))
          (for/and ([(key value) (in-hash left)])
            (and (hash-has-key? right key)
                 (json-equivalent? value (hash-ref right key)))))]
    [(and (list? left) (list? right))
     (and (= (length left) (length right))
          (for/and ([left-value (in-list left)]
                    [right-value (in-list right)])
            (json-equivalent? left-value right-value)))]
    [else (equal? left right)]))

(define (compare-section baseline current section changed-message)
  (define before (index-section (snapshot-section baseline section) section "baseline"))
  (define after (index-section (snapshot-section current section) section "current"))
  (define names (sort (remove-duplicates (append (hash-keys before) (hash-keys after))) string<?))
  (define label
    (hash-ref (hash 'records "record" 'enums "enum" 'rpcs "RPC"
                    'events "event" 'states "state"
                    'device-rpcs "device RPC export")
              section))
  (for/fold ([breakages '()] [additions '()]) ([name (in-list names)])
    (cond
      [(not (hash-has-key? after name))
       (values
        (cons (change section name "removed"
                      (format "~a ~a was removed" label name)
                      (hash-ref before name))
              breakages)
        additions)]
      [(not (hash-has-key? before name))
       (values breakages
               (cons (change section name "added"
                             (format "~a ~a was added" label name)
                             #f
                             (hash-ref after name))
                     additions))]
      [(not (json-equivalent? (hash-ref before name) (hash-ref after name)))
       (values
        (cons (change section name "changed"
                      (format "~a ~a: ~a" label name changed-message)
                      (hash-ref before name)
                      (hash-ref after name))
              breakages)
        additions)]
      [else (values breakages additions)])))

(define (compare-schema-snapshots baseline current)
  (validate-snapshot! baseline "baseline")
  (validate-snapshot! current "current")
  (define protocol-breakages
    (if (equal? (hash-ref baseline 'rvt-protocol)
                (hash-ref current 'rvt-protocol))
        '()
        (list
         (change 'protocol "RVT1" "changed"
                 "the RVT protocol version changed"
                 (hash-ref baseline 'rvt-protocol)
                 (hash-ref current 'rvt-protocol)))))
  (define-values (record-breakages record-additions)
    (compare-section baseline current 'records
                     "record fields, order, or types changed"))
  (define-values (rpc-breakages rpc-additions)
    (compare-section baseline current 'rpcs
                     "RPC arguments, order, or result type changed"))
  (define-values (enum-breakages enum-additions)
    (compare-section baseline current 'enums "enum cases or order changed"))
  (define-values (event-breakages event-additions)
    (compare-section baseline current 'events "event type changed"))
  (define-values (state-breakages state-additions)
    (compare-section baseline current 'states "state type changed"))
  (define-values (device-breakages device-additions)
    (compare-section baseline current 'device-rpcs
                     "device RPC export changed"))
  (define breakages
    (append protocol-breakages
            (reverse record-breakages)
            (reverse enum-breakages)
            (reverse rpc-breakages)
            (reverse event-breakages)
            (reverse state-breakages)
            (reverse device-breakages)))
  (define additions
    (append (reverse record-additions)
            (reverse enum-additions)
            (reverse rpc-additions)
            (reverse event-additions)
            (reverse state-additions)
            (reverse device-additions)))
  (hash 'compatible (null? breakages)
        'format schema-snapshot-format
        'format-version schema-snapshot-version
        'breaking-changes breakages
        'compatible-additions additions))

(define (check-schema-compatibility! project baseline-path)
  (define baseline
    (call-with-input-file baseline-path read-json))
  (compare-schema-snapshots baseline (schema-snapshot project)))
