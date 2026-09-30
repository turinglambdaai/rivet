#lang racket/base

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "project.rkt")

(provide generate-clients!
         schema-snapshot
         write-schema-snapshot!
         check-schema-compatibility!)

(struct schema-rpc (name arg-names arg-types result-type) #:transparent)
(struct schema-event (name type) #:transparent)
(struct schema-state (name type) #:transparent)
(struct schema-record (name field-names field-types) #:transparent)
(struct schema-enum (name cases) #:transparent)

(define schema-snapshot-format "rivet-schema")
(define schema-snapshot-version 1)
(define scalar-types '(String Int64 Bool Bytes Void Any))

(define (load-schema backend)
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
  (hash
   'format schema-snapshot-format
   'format-version schema-snapshot-version
   'rvt-protocol (project-ref project 'protocol)
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
  ;; `enums` was added additively to snapshot format v1. Baselines written by
  ;; earlier v1 implementations omit it and therefore mean an empty enum set.
  (define value (hash-ref snapshot key (if (eq? key 'enums) '() #f)))
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
  (for ([section (in-list '(records enums rpcs events states))])
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
                    'events "event" 'states "state")
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
  (define breakages
    (append protocol-breakages
            (reverse record-breakages)
            (reverse enum-breakages)
            (reverse rpc-breakages)
            (reverse event-breakages)
            (reverse state-breakages)))
  (define additions
    (append (reverse record-additions)
            (reverse enum-additions)
            (reverse rpc-additions)
            (reverse event-additions)
            (reverse state-additions)))
  (hash 'compatible (null? breakages)
        'format schema-snapshot-format
        'format-version schema-snapshot-version
        'breaking-changes breakages
        'compatible-additions additions))

(define (check-schema-compatibility! project baseline-path)
  (define baseline
    (call-with-input-file baseline-path read-json))
  (compare-schema-snapshots baseline (schema-snapshot project)))

(define swift-keywords
  '("class" "struct" "enum" "protocol" "extension" "func" "let" "var"
    "import" "return" "throw" "throws" "async" "await" "actor" "self"
    "switch" "case" "default" "if" "else" "for" "while" "in" "where"))

(define cpp-keywords
  '("class" "struct" "enum" "template" "typename" "auto" "return" "throw"
    "switch" "case" "default" "if" "else" "for" "while" "namespace"
    "public" "private" "protected" "operator" "new" "delete"))

(define (identifier value keywords)
  (define raw
    (regexp-replace* #px"[^A-Za-z0-9_]"
                     (if (symbol? value) (symbol->string value) value)
                     "_"))
  (define result
    (if (or (string=? raw "") (regexp-match? #px"^[0-9]" raw))
        (string-append "_" raw)
        raw))
  (if (member result keywords) (string-append "rivet_" result) result))

;; Hard keywords only: soft/contextual keywords such as `value`, `get`, and
;; `suspend` remain valid identifiers everywhere the generator emits them, and
;; keeping the raw name preserves parity with the Swift/C++ clients.
(define kotlin-keywords
  '("as" "break" "class" "continue" "do" "else" "false" "for" "fun" "if"
    "in" "interface" "is" "null" "object" "package" "return" "super"
    "this" "throw" "true" "try" "typealias" "typeof" "val" "var" "when"
    "while" "init"))

(define (swift-id value) (identifier value swift-keywords))
(define (cpp-id value) (identifier value cpp-keywords))
(define (kotlin-id value) (identifier value kotlin-keywords))

(define (upper-first value)
  (if (zero? (string-length value))
      value
      (string-append (string-upcase (substring value 0 1))
                     (substring value 1))))

(define (octal3 n)
  (define raw (number->string n 8))
  (string-append (make-string (- 3 (string-length raw)) #\0) raw))

(define (swift-string-literal value)
  (string-append
   "\""
   (apply
    string-append
    (for/list ([ch (in-string value)])
      (define code (char->integer ch))
      (cond
        [(char=? ch #\\) "\\\\"]
        [(char=? ch #\") "\\\""]
        [(char=? ch #\newline) "\\n"]
        [(char=? ch #\return) "\\r"]
        [(char=? ch #\tab) "\\t"]
        [(or (< code 32) (= code 127))
         (format "\\u{~a}" (string-upcase (number->string code 16)))]
        [else (string ch)])))
   "\""))

(define (cpp-string-literal value)
  (string-append
   "\""
   (apply
    string-append
    (for/list ([ch (in-string value)])
      (define code (char->integer ch))
      (cond
        [(char=? ch #\\) "\\\\"]
        [(char=? ch #\") "\\\""]
        [(char=? ch #\newline) "\\n"]
        [(char=? ch #\return) "\\r"]
        [(char=? ch #\tab) "\\t"]
        [(or (< code 32) (= code 127)) (string-append "\\" (octal3 code))]
        [else (string ch)])))
   "\""))

(define (kotlin-string-literal value)
  (string-append
   "\""
   (apply
    string-append
    (for/list ([ch (in-string value)])
      (define code (char->integer ch))
      (cond
        [(char=? ch #\\) "\\\\"]
        [(char=? ch #\") "\\\""]
        [(char=? ch #\newline) "\\n"]
        [(char=? ch #\return) "\\r"]
        [(char=? ch #\tab) "\\t"]
        [(char=? ch #\$) "\\$"]
        [(or (< code 32) (= code 127))
         (format "\\u~a" (string-upcase (pad-hex-4 code)))]
        [else (string ch)])))
   "\""))

(define (pad-hex-4 n)
  (define raw (number->string n 16))
  (string-append (make-string (max 0 (- 4 (string-length raw))) #\0) raw))

(define (check-unique-native-names! language entries)
  (define seen (make-hash))
  (for ([entry (in-list entries)])
    (define generated (car entry))
    (define source (cdr entry))
    (define previous (hash-ref seen generated #f))
    (when previous
      (raise-arguments-error
       'generate-clients!
       "native API name collision after identifier normalization"
       "language" language
       "generated name" generated
       "first declaration" previous
       "second declaration" source))
    (hash-set! seen generated source)))

(define (cpp-event-type-name event)
  (string-append (upper-first (cpp-id (schema-event-name event))) "Event"))

(define (validate-native-identifiers! rpcs events states records enums)
  (for ([info (in-list rpcs)])
    (define rpc-label (format "RPC ~a" (schema-rpc-name info)))
    (check-unique-native-names!
     "Swift arguments"
     (for/list ([name (in-list (schema-rpc-arg-names info))])
       (cons (swift-id name) (format "~a argument ~a" rpc-label name))))
    (check-unique-native-names!
     "C++ arguments"
     (for/list ([name (in-list (schema-rpc-arg-names info))])
       (cons (cpp-id name) (format "~a argument ~a" rpc-label name))))
    (check-unique-native-names!
     "Kotlin arguments"
     (for/list ([name (in-list (schema-rpc-arg-names info))])
       (cons (kotlin-id name) (format "~a argument ~a" rpc-label name)))))

  (check-unique-native-names!
   "Swift schema types"
   (append
    (for/list ([record (in-list records)])
      (cons (record-native-name (schema-record-name record) swift-id)
            (format "Record ~a" (schema-record-name record))))
    (for/list ([enum (in-list enums)])
      (cons (record-native-name (schema-enum-name enum) swift-id)
            (format "Enum ~a" (schema-enum-name enum))))))
  (check-unique-native-names!
   "C++ schema types"
   (append
    (for/list ([record (in-list records)])
      (cons (record-native-name (schema-record-name record) cpp-id)
            (format "Record ~a" (schema-record-name record))))
    (for/list ([enum (in-list enums)])
      (cons (record-native-name (schema-enum-name enum) cpp-id)
            (format "Enum ~a" (schema-enum-name enum))))))
  (check-unique-native-names!
   "Kotlin schema types"
   (append
    ;; A schema type named after a runtime/generated identifier would shadow it
    ;; inside the single generated file.
    (for/list ([reserved (in-list '("RivetValue" "RivetClient" "RivetAPI"
                                    "RivetEvent" "RivetGeneratedException"
                                    "RivetGeneratedConfig"))])
      (cons reserved "Kotlin reserved generated name"))
    (for/list ([record (in-list records)])
      (cons (record-native-name (schema-record-name record) kotlin-id)
            (format "Record ~a" (schema-record-name record))))
    (for/list ([enum (in-list enums)])
      (cons (record-native-name (schema-enum-name enum) kotlin-id)
            (format "Enum ~a" (schema-enum-name enum))))))

  (for ([record (in-list records)])
    (check-unique-native-names!
     "Swift Record fields"
     (for/list ([field (in-list (schema-record-field-names record))])
       (cons (swift-id field) (format "Record ~a field ~a" (schema-record-name record) field))))
    (check-unique-native-names!
     "C++ Record fields"
     (for/list ([field (in-list (schema-record-field-names record))])
       (cons (cpp-id field) (format "Record ~a field ~a" (schema-record-name record) field))))
    (check-unique-native-names!
     "Kotlin Record fields"
     (for/list ([field (in-list (schema-record-field-names record))])
       (cons (kotlin-id field) (format "Record ~a field ~a" (schema-record-name record) field)))))

  (for ([enum (in-list enums)])
    (check-unique-native-names!
     "Swift Enum cases"
     (for/list ([case (in-list (schema-enum-cases enum))])
       (cons (swift-id case) (format "Enum ~a case ~a" (schema-enum-name enum) case))))
    (check-unique-native-names!
     "C++ Enum cases"
     (for/list ([case (in-list (schema-enum-cases enum))])
       (cons (cpp-id case) (format "Enum ~a case ~a" (schema-enum-name enum) case))))
    (check-unique-native-names!
     "Kotlin Enum cases"
     (for/list ([case (in-list (schema-enum-cases enum))])
       (cons (kotlin-id case) (format "Enum ~a case ~a" (schema-enum-name enum) case)))))

  (check-unique-native-names!
   "Swift API"
   (append
    (for/list ([info (in-list rpcs)])
      (cons (swift-id (schema-rpc-name info))
            (format "RPC ~a" (schema-rpc-name info))))
    (append*
     (for/list ([state (in-list states)])
       (define suffix (upper-first (swift-id (schema-state-name state))))
       (list (cons (string-append "get" suffix)
                   (format "State getter ~a" (schema-state-name state)))
             (cons (string-append "set" suffix)
                   (format "State setter ~a" (schema-state-name state))))))))

  ;; Kotlin mirrors the Swift member surface: RPC methods plus get/set accessors
  ;; with an UpperFirst state suffix. RivetAPI also owns a `client` property.
  (check-unique-native-names!
   "Kotlin API"
   (append
    (list (cons "client" "RivetAPI constructor property"))
    (for/list ([info (in-list rpcs)])
      (cons (kotlin-id (schema-rpc-name info))
            (format "RPC ~a" (schema-rpc-name info))))
    (append*
     (for/list ([state (in-list states)])
       (define suffix (upper-first (kotlin-id (schema-state-name state))))
       (list (cons (string-append "get" suffix)
                   (format "State getter ~a" (schema-state-name state)))
             (cons (string-append "set" suffix)
                   (format "State setter ~a" (schema-state-name state))))))))

  ;; Event payloads become nested data classes named with UpperFirst, so two
  ;; events differing only in case would collapse onto one class.
  (check-unique-native-names!
   "Kotlin Event"
   (for/list ([event (in-list events)])
     (cons (upper-first (kotlin-id (schema-event-name event)))
           (format "Event ~a" (schema-event-name event)))))

  ;; C++ emits both the historical future API and a non-blocking completion API.
  ;; Check all generated names together so an RPC named foo_async cannot collide
  ;; with the async companion generated for an RPC named foo.
  (check-unique-native-names!
   "C++ API"
   (append
    (append*
     (for/list ([info (in-list rpcs)])
       (define name (cpp-id (schema-rpc-name info)))
       (list (cons name (format "RPC ~a" (schema-rpc-name info)))
             (cons (string-append name "_async")
                   (format "RPC async companion ~a" (schema-rpc-name info))))))
    (append*
     (for/list ([state (in-list states)])
       (define name (cpp-id (schema-state-name state)))
       (list (cons (string-append "get_" name)
                   (format "State getter ~a" (schema-state-name state)))
             (cons (string-append "get_" name "_async")
                   (format "State async getter ~a" (schema-state-name state)))
             (cons (string-append "set_" name)
                   (format "State setter ~a" (schema-state-name state)))
             (cons (string-append "set_" name "_async")
                   (format "State async setter ~a" (schema-state-name state))))))))

  (check-unique-native-names!
   "Swift Event"
   (for/list ([event (in-list events)])
     (cons (swift-id (schema-event-name event))
           (format "Event ~a" (schema-event-name event)))))

  (check-unique-native-names!
   "C++ Event"
   (for/list ([event (in-list events)])
     (cons (cpp-event-type-name event)
           (format "Event ~a" (schema-event-name event))))))

(define current-records (make-parameter '()))
(define current-enums (make-parameter '()))

(define (schema-record-for type)
  (and (symbol? type)
       (findf (lambda (record) (eq? (schema-record-name record) type))
              (current-records))))

(define (schema-enum-for type)
  (and (symbol? type)
       (findf (lambda (enum) (eq? (schema-enum-name enum) type))
              (current-enums))))

(define (record-native-name type id-proc)
  (upper-first (id-proc type)))

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

(define (swift-type type)
  (match type
    ['String "String"]
    ['Int64 "Int64"]
    ['Bool "Bool"]
    ['Bytes "Data"]
    ['Void "Void"]
    ['Any "RivetValue"]
    [(list 'List inner) (format "[~a]" (swift-type inner))]
    [(list 'Optional inner) (format "~a?" (swift-type inner))]
    [_
     (if (or (schema-record-for type) (schema-enum-for type))
         (record-native-name type swift-id)
         (error 'generate-clients! "unsupported Swift type: ~e" type))]))

(define (cpp-type type)
  (match type
    ['String "std::string"]
    ['Int64 "std::int64_t"]
    ['Bool "bool"]
    ['Bytes "rivet::Bytes"]
    ['Void "void"]
    ['Any "rivet::Value"]
    [(list 'List inner) (format "std::vector<~a>" (cpp-type inner))]
    [(list 'Optional inner) (format "std::optional<~a>" (cpp-type inner))]
    [_
     (if (or (schema-record-for type) (schema-enum-for type))
         (record-native-name type cpp-id)
         (error 'generate-clients! "unsupported C++ type: ~e" type))]))

(define (kotlin-type type)
  (match type
    ['String "String"]
    ['Int64 "Long"]
    ['Bool "Boolean"]
    ['Bytes "ByteArray"]
    ['Void "Unit"]
    ['Any "RivetValue"]
    [(list 'List inner) (format "List<~a>" (kotlin-type inner))]
    [(list 'Optional inner) (format "~a?" (kotlin-type inner))]
    [_
     (if (or (schema-record-for type) (schema-enum-for type))
         (record-native-name type kotlin-id)
         (error 'generate-clients! "unsupported Kotlin type: ~e" type))]))

(define (swift-record-definition record)
  (define name (record-native-name (schema-record-name record) swift-id))
  (define fields (map swift-id (schema-record-field-names record)))
  (define types (schema-record-field-types record))
  (define declarations
    (apply string-append
           (for/list ([field (in-list fields)] [type (in-list types)])
             (format "    public let ~a: ~a\n" field (swift-type type)))))
  (define params
    (string-join
     (for/list ([field (in-list fields)] [type (in-list types)])
       (format "~a: ~a" field (swift-type type)))
     ", "))
  (define assignments
    (apply string-append
           (for/list ([field (in-list fields)])
             (format "        self.~a = ~a\n" field field))))
  (format "public struct ~a: Sendable {\n~a    public init(~a) {\n~a    }\n}\n\n"
          name declarations params assignments))

(define (cpp-record-definition record)
  (define name (record-native-name (schema-record-name record) cpp-id))
  (define fields (map cpp-id (schema-record-field-names record)))
  (define types (schema-record-field-types record))
  (string-append
   (format "struct ~a {\n" name)
   (apply string-append
          (for/list ([field (in-list fields)] [type (in-list types)])
            (format "  ~a ~a;\n" (cpp-type type) field)))
   "};\n\n"))

(define (swift-enum-definition enum)
  (define name (record-native-name (schema-enum-name enum) swift-id))
  (string-append
   (format "public enum ~a: String, Sendable {\n" name)
   (apply string-append
          (for/list ([case (in-list (schema-enum-cases enum))])
            (format "    case ~a = ~a\n"
                    (swift-id case)
                    (swift-string-literal (symbol->string case)))))
   "}\n\n"))

(define (cpp-enum-definition enum)
  (define name (record-native-name (schema-enum-name enum) cpp-id))
  (format "enum class ~a { ~a };\n\n"
          name
          (string-join (map cpp-id (schema-enum-cases enum)) ", ")))

(define (swift-encoder type)
  (define key (type-key type))
  (define record (schema-record-for type))
  (define enum (schema-enum-for type))
  (cond
    [record
     (define fields (map swift-id (schema-record-field-names record)))
     (define types (schema-record-field-types record))
     (define encoded
       (string-join
        (for/list ([field (in-list fields)] [field-type (in-list types)])
          (format "encode_~a(v.~a)" (type-key field-type) field))
        ", "))
     (format "private func encode_~a(_ v: ~a) -> RivetValue { .list([~a]) }\n"
             key (swift-type type) encoded)]
    [enum
     (format "private func encode_~a(_ v: ~a) -> RivetValue { .string(v.rawValue) }\n"
             key (swift-type type))]
    [else
     (match type
       ['String (format "private func encode_~a(_ v: String) -> RivetValue { .string(v) }\n" key)]
       ['Int64 (format "private func encode_~a(_ v: Int64) -> RivetValue { .int64(v) }\n" key)]
       ['Bool (format "private func encode_~a(_ v: Bool) -> RivetValue { .bool(v) }\n" key)]
       ['Bytes (format "private func encode_~a(_ v: Data) -> RivetValue { .bytes(v) }\n" key)]
       ['Void (format "private func encode_~a(_ v: Void) -> RivetValue { .null }\n" key)]
       ['Any (format "private func encode_~a(_ v: RivetValue) -> RivetValue { v }\n" key)]
       [(list 'List inner)
        (format "private func encode_~a(_ v: ~a) -> RivetValue { .list(v.map(encode_~a)) }\n"
                key (swift-type type) (type-key inner))]
       [(list 'Optional inner)
        (format "private func encode_~a(_ v: ~a) -> RivetValue { v.map(encode_~a) ?? .null }\n"
                key (swift-type type) (type-key inner))])]))

(define (swift-decoder type)
  (define key (type-key type))
  (define expected (swift-string-literal (format "~s" type)))
  (define record (schema-record-for type))
  (define enum (schema-enum-for type))
  (cond
    [record
     (define fields (map swift-id (schema-record-field-names record)))
     (define types (schema-record-field-types record))
     (define decoded
       (string-join
        (for/list ([field (in-list fields)]
                   [field-type (in-list types)]
                   [index (in-naturals)])
          (format "~a: try decode_~a(xs[~a])" field (type-key field-type) index))
        ", "))
     (format "private func decode_~a(_ v: RivetValue) throws -> ~a { guard case .list(let xs) = v, xs.count == ~a else { throw RivetGeneratedError.typeMismatch(~a) }; return ~a(~a) }\n"
             key (swift-type type) (length fields) expected (swift-type type) decoded)]
    [enum
     (format "private func decode_~a(_ v: RivetValue) throws -> ~a { guard case .string(let x) = v, let result = ~a(rawValue: x) else { throw RivetGeneratedError.typeMismatch(~a) }; return result }\n"
             key (swift-type type) (swift-type type) expected)]
    [else
     (match type
       ['String (format "private func decode_~a(_ v: RivetValue) throws -> String { guard case .string(let x) = v else { throw RivetGeneratedError.typeMismatch(~a) }; return x }\n" key expected)]
       ['Int64 (format "private func decode_~a(_ v: RivetValue) throws -> Int64 { guard case .int64(let x) = v else { throw RivetGeneratedError.typeMismatch(~a) }; return x }\n" key expected)]
       ['Bool (format "private func decode_~a(_ v: RivetValue) throws -> Bool { guard case .bool(let x) = v else { throw RivetGeneratedError.typeMismatch(~a) }; return x }\n" key expected)]
       ['Bytes (format "private func decode_~a(_ v: RivetValue) throws -> Data { guard case .bytes(let x) = v else { throw RivetGeneratedError.typeMismatch(~a) }; return x }\n" key expected)]
       ['Void (format "private func decode_~a(_ v: RivetValue) throws -> Void { guard case .null = v else { throw RivetGeneratedError.typeMismatch(~a) } }\n" key expected)]
       ['Any (format "private func decode_~a(_ v: RivetValue) throws -> RivetValue { v }\n" key)]
       [(list 'List inner)
        (format "private func decode_~a(_ v: RivetValue) throws -> ~a { guard case .list(let xs) = v else { throw RivetGeneratedError.typeMismatch(~a) }; return try xs.map(decode_~a) }\n"
                key (swift-type type) expected (type-key inner))]
       [(list 'Optional inner)
        (format "private func decode_~a(_ v: RivetValue) throws -> ~a { if case .null = v { return nil }; return try decode_~a(v) }\n"
                key (swift-type type) (type-key inner))])]))

(define (swift-rpc-method info)
  (define names (map swift-id (schema-rpc-arg-names info)))
  (define types (schema-rpc-arg-types info))
  (define result (schema-rpc-result-type info))
  (define params
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "~a: ~a" name (swift-type type)))
     ", "))
  (define encoded
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "encode_~a(~a)" (type-key type) name))
     ", "))
  (format
   "    public func ~a(~a) async throws -> ~a {\n        let result = try await client.call(~a, arguments: [~a])\n        return try decode_~a(result)\n    }\n"
   (swift-id (schema-rpc-name info)) params (swift-type result)
   (swift-string-literal (symbol->string (schema-rpc-name info))) encoded (type-key result)))

(define (swift-state-methods state)
  (define raw-name (symbol->string (schema-state-name state)))
  (define suffix (upper-first (swift-id raw-name)))
  (define type (schema-state-type state))
  (format
   "    public func get~a() async throws -> ~a {\n        let result = try await client.getState(~a)\n        return try decode_~a(result)\n    }\n    @discardableResult\n    public func set~a(_ value: ~a) async throws -> ~a {\n        let result = try await client.setState(~a, value: encode_~a(value))\n        return try decode_~a(result)\n    }\n"
   suffix (swift-type type) (swift-string-literal raw-name) (type-key type)
   suffix (swift-type type) (swift-type type) (swift-string-literal raw-name) (type-key type) (type-key type)))

(define (generate-swift-events events)
  (if (null? events)
      ""
      (string-append
       "public enum RivetEvent: Sendable {\n"
       (apply
        string-append
        (for/list ([event (in-list events)])
          (format "    case ~a(~a)\n"
                  (swift-id (schema-event-name event))
                  (swift-type (schema-event-type event)))))
       "\n    public static func decode(name: String, value: RivetValue) throws -> RivetEvent {\n        switch name {\n"
       (apply
        string-append
        (for/list ([event (in-list events)])
          (format "        case ~a: return .~a(try decode_~a(value))\n"
                  (swift-string-literal (symbol->string (schema-event-name event)))
                  (swift-id (schema-event-name event))
                  (type-key (schema-event-type event)))))
       "        default: throw RivetGeneratedError.unknownEvent(name)\n        }\n    }\n}\n\n")))

(define (generate-swift rpcs events states records enums module-name entry-name)
  (define types (all-types rpcs events states records enums))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\nimport Foundation\nimport RivetRuntime\n\n"
   "public enum RivetGeneratedError: Error { case typeMismatch(String); case unknownEvent(String) }\n"
   (format "public enum RivetGeneratedConfig { public static let moduleName = ~a; public static let entryName = ~a }\n\n"
           (swift-string-literal module-name)
           (swift-string-literal entry-name))
   (apply string-append (map swift-enum-definition enums))
   (apply string-append (map swift-record-definition (order-records records)))
   (apply string-append (map swift-encoder types))
   "\n"
   (apply string-append (map swift-decoder types))
   "\n"
   (generate-swift-events events)
   "public struct RivetAPI: Sendable {\n    public let client: RivetClient\n    public init(client: RivetClient) { self.client = client }\n\n"
   (apply string-append (map swift-rpc-method rpcs))
   (if (null? states) "" "\n    // Shared state\n")
   (apply string-append (map swift-state-methods states))
   "}\n"))

(define (cpp-encoder type)
  (define key (type-key type))
  (define record (schema-record-for type))
  (define enum (schema-enum-for type))
  (cond
    [record
     (define fields (map cpp-id (schema-record-field-names record)))
     (define types (schema-record-field-types record))
     (define pushes
       (apply string-append
              (for/list ([field (in-list fields)] [field-type (in-list types)])
                (format " r.push_back(encode_~a(v.~a));" (type-key field-type) field))))
     (format "inline rivet::Value encode_~a(~a const& v) { rivet::Value::List r; r.reserve(~a);~a return rivet::Value(std::move(r)); }\n"
             key (cpp-type type) (length fields) pushes)]
    [enum
     (define cases
       (apply string-append
              (for/list ([case (in-list (schema-enum-cases enum))])
                (format " case ~a::~a: return rivet::Value(std::string(~a));"
                        (cpp-type type)
                        (cpp-id case)
                        (cpp-string-literal (symbol->string case))))))
     (format "inline rivet::Value encode_~a(~a v) { switch (v) {~a } throw std::runtime_error(\"invalid Rivet enum value\"); }\n"
             key (cpp-type type) cases)]
    [else
     (match type
       ['String (format "inline rivet::Value encode_~a(std::string const& v) { return rivet::Value(v); }\n" key)]
       ['Int64 (format "inline rivet::Value encode_~a(std::int64_t v) { return rivet::Value(v); }\n" key)]
       ['Bool (format "inline rivet::Value encode_~a(bool v) { return rivet::Value(v); }\n" key)]
       ['Bytes (format "inline rivet::Value encode_~a(rivet::Bytes const& v) { return rivet::Value(v); }\n" key)]
       ['Void (format "inline rivet::Value encode_~a() { return rivet::Value{}; }\n" key)]
       ['Any (format "inline rivet::Value encode_~a(rivet::Value v) { return v; }\n" key)]
       [(list 'List inner)
        (format "inline rivet::Value encode_~a(~a const& xs) { rivet::Value::List r; r.reserve(xs.size()); for (auto const& x : xs) r.push_back(encode_~a(x)); return rivet::Value(std::move(r)); }\n"
                key (cpp-type type) (type-key inner))]
       [(list 'Optional inner)
        (format "inline rivet::Value encode_~a(~a const& v) { return v ? encode_~a(*v) : rivet::Value{}; }\n"
                key (cpp-type type) (type-key inner))])]))

(define (cpp-decoder type)
  (define key (type-key type))
  (define error-text
    (cpp-string-literal
     (string-append "Rivet result type mismatch: " (format "~s" type))))
  (define record (schema-record-for type))
  (define enum (schema-enum-for type))
  (cond
    [record
     (define types (schema-record-field-types record))
     (define decoded
       (string-join
        (for/list ([field-type (in-list types)] [index (in-naturals)])
          (format "decode_~a((*p)[~a])" (type-key field-type) index))
        ", "))
     (format "inline ~a decode_~a(rivet::Value const& v) { auto p = std::get_if<rivet::Value::List>(&v.data); if (!p || p->size() != ~a) throw std::runtime_error(~a); return ~a{~a}; }\n"
             (cpp-type type) key (length types) error-text (cpp-type type) decoded)]
    [enum
     (define cases
       (apply string-append
              (for/list ([case (in-list (schema-enum-cases enum))])
                (format " if (*p == ~a) return ~a::~a;"
                        (cpp-string-literal (symbol->string case))
                        (cpp-type type)
                        (cpp-id case)))))
     (format "inline ~a decode_~a(rivet::Value const& v) { auto p = std::get_if<std::string>(&v.data); if (p) {~a } throw std::runtime_error(~a); }\n"
             (cpp-type type) key cases error-text)]
    [else
     (match type
       ['String (format "inline std::string decode_~a(rivet::Value const& v) { if (auto p = std::get_if<std::string>(&v.data)) return *p; throw std::runtime_error(~a); }\n" key error-text)]
       ['Int64 (format "inline std::int64_t decode_~a(rivet::Value const& v) { if (auto p = std::get_if<std::int64_t>(&v.data)) return *p; throw std::runtime_error(~a); }\n" key error-text)]
       ['Bool (format "inline bool decode_~a(rivet::Value const& v) { if (auto p = std::get_if<bool>(&v.data)) return *p; throw std::runtime_error(~a); }\n" key error-text)]
       ['Bytes (format "inline rivet::Bytes decode_~a(rivet::Value const& v) { if (auto p = std::get_if<rivet::Bytes>(&v.data)) return *p; throw std::runtime_error(~a); }\n" key error-text)]
       ['Void (format "inline void decode_~a(rivet::Value const& v) { if (!std::holds_alternative<std::monostate>(v.data)) throw std::runtime_error(~a); }\n" key error-text)]
       ['Any (format "inline rivet::Value decode_~a(rivet::Value const& v) { return v; }\n" key)]
       [(list 'List inner)
        (format "inline ~a decode_~a(rivet::Value const& v) { auto p = std::get_if<rivet::Value::List>(&v.data); if (!p) throw std::runtime_error(~a); ~a r; r.reserve(p->size()); for (auto const& x : *p) r.push_back(decode_~a(x)); return r; }\n"
                (cpp-type type) key error-text (cpp-type type) (type-key inner))]
       [(list 'Optional inner)
        (format "inline ~a decode_~a(rivet::Value const& v) { if (std::holds_alternative<std::monostate>(v.data)) return std::nullopt; return decode_~a(v); }\n"
                (cpp-type type) key (type-key inner))])]))

(define (cpp-future result-type raw-expression)
  (define result (cpp-type result-type))
  (define decode
    (if (eq? result-type 'Void)
        (format "detail::decode_~a(raw.get());" (type-key result-type))
        (format "return detail::decode_~a(raw.get());" (type-key result-type))))
  (format
   "auto raw = ~a; return std::async(std::launch::deferred, [raw = std::move(raw)]() mutable -> ~a { ~a });"
   raw-expression result decode))

(define (cpp-async-handler result-type backend-namespace)
  (define result (cpp-type result-type))
  (define decode
    (if (eq? result-type 'Void)
        (format "detail::decode_~a(*raw.value);" (type-key result-type))
        (format "result.value = detail::decode_~a(*raw.value);" (type-key result-type))))
  (format
   "[completion = std::move(completion)](~a::CallResult raw) mutable { Result<~a> result; if (raw.error) { result.error = raw.error; } else { try { if (!raw.value) throw std::runtime_error(\"Rivet async call completed without a value\"); ~a } catch (...) { result.error = std::current_exception(); } } completion(std::move(result)); }"
   backend-namespace result decode))

(define (cpp-completion-type type)
  (format "std::function<void(Result<~a>)>" (cpp-type type)))

(define (cpp-append-param params extra)
  (if (string=? params "") extra (string-append params ", " extra)))

(define (cpp-rpc-method info backend-namespace)
  (define names (map cpp-id (schema-rpc-arg-names info)))
  (define types (schema-rpc-arg-types info))
  (define result-type (schema-rpc-result-type info))
  (define params
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "~a ~a" (cpp-type type) name))
     ", "))
  (define encoded
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "detail::encode_~a(~a)" (type-key type) name))
     ", "))
  (define rpc-name (cpp-string-literal (symbol->string (schema-rpc-name info))))
  (define async-params
    (cpp-append-param params
                      (format "~a completion" (cpp-completion-type result-type))))
  (format
   "  std::future<~a> ~a(~a) { ~a }\n  [[nodiscard]] std::uint64_t ~a_async(~a) { if (!completion) throw std::invalid_argument(\"Rivet async completion handler is empty\"); return backend_.request_async(~a, rivet::Value::List{~a}, ~a); }\n"
   (cpp-type result-type)
   (cpp-id (schema-rpc-name info))
   params
   (cpp-future result-type
               (format "backend_.call(~a, rivet::Value::List{~a})"
                       rpc-name encoded))
   (cpp-id (schema-rpc-name info))
   async-params
   rpc-name encoded (cpp-async-handler result-type backend-namespace)))

(define (cpp-state-methods state backend-namespace)
  (define name (cpp-id (schema-state-name state)))
  (define raw-name (symbol->string (schema-state-name state)))
  (define type (schema-state-type state))
  (define completion-type (cpp-completion-type type))
  (format
   "  std::future<~a> get_~a() { ~a }\n  [[nodiscard]] std::uint64_t get_~a_async(~a completion) { if (!completion) throw std::invalid_argument(\"Rivet async completion handler is empty\"); return backend_.get_state_async(~a, ~a); }\n  std::future<~a> set_~a(~a value) { ~a }\n  [[nodiscard]] std::uint64_t set_~a_async(~a value, ~a completion) { if (!completion) throw std::invalid_argument(\"Rivet async completion handler is empty\"); return backend_.set_state_async(~a, detail::encode_~a(value), ~a); }\n"
   (cpp-type type) name
   (cpp-future type (format "backend_.get_state(~a)" (cpp-string-literal raw-name)))
   name completion-type (cpp-string-literal raw-name) (cpp-async-handler type backend-namespace)
   (cpp-type type) name (cpp-type type)
   (cpp-future type
               (format "backend_.set_state(~a, detail::encode_~a(value))"
                       (cpp-string-literal raw-name) (type-key type)))
   name (cpp-type type) completion-type
   (cpp-string-literal raw-name) (type-key type) (cpp-async-handler type backend-namespace)))

(define (generate-cpp-events events)
  (if (null? events)
      ""
      (string-append
       (apply
        string-append
        (for/list ([event (in-list events)])
          (format "struct ~a { ~a value; };\n"
                  (cpp-event-type-name event)
                  (cpp-type (schema-event-type event)))))
       (format "using Event = std::variant<~a>;\n"
               (string-join (map cpp-event-type-name events) ", "))
       "inline Event decode_event(std::string const& name, rivet::Value const& value) {\n"
       (apply
        string-append
        (for/list ([event (in-list events)])
          (format "  if (name == ~a) return Event{~a{detail::decode_~a(value)}};\n"
                  (cpp-string-literal (symbol->string (schema-event-name event)))
                  (cpp-event-type-name event)
                  (type-key (schema-event-type event)))))
       "  throw std::runtime_error(\"unknown Rivet event: \" + name);\n}\n\n")))

(define (generate-cpp rpcs events states records enums module-name entry-name backend-namespace)
  (define types (all-types rpcs events states records enums))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n#pragma once\n\n#include <cstdint>\n#include <exception>\n#include <functional>\n#include <future>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <variant>\n#include <vector>\n\n#include \"backend.hpp\"\n\nnamespace rivet_app {\n"
   (format "inline constexpr char kModuleName[] = ~a;\ninline constexpr char kEntryName[] = ~a;\n\n"
           (cpp-string-literal module-name)
           (cpp-string-literal entry-name))
   (apply string-append (map cpp-enum-definition enums))
   (apply string-append (map cpp-record-definition (order-records records)))
   "template <typename T>\nstruct Result {\n  std::optional<T> value;\n  std::exception_ptr error;\n  bool succeeded() const noexcept { return value.has_value() && !error; }\n  T const& get() const { if (error) std::rethrow_exception(error); if (!value) throw std::runtime_error(\"Rivet async result has no value\"); return *value; }\n};\n\ntemplate <>\nstruct Result<void> {\n  std::exception_ptr error;\n  bool succeeded() const noexcept { return !error; }\n  void get() const { if (error) std::rethrow_exception(error); }\n};\n\n"
   "namespace detail {\n"
   (apply string-append (map cpp-encoder types))
   "\n"
   (apply string-append (map cpp-decoder types))
   "}  // namespace detail\n\n"
   (generate-cpp-events events)
   (format "class API {\n public:\n  explicit API(~a::Backend& backend) : backend_(backend) {}\n\n"
           backend-namespace)
   (apply string-append
          (for/list ([rpc (in-list rpcs)])
            (cpp-rpc-method rpc backend-namespace)))
   (if (null? states) "" "\n  // Shared state\n")
   (apply string-append
          (for/list ([state (in-list states)])
            (cpp-state-methods state backend-namespace)))
   (format "\n private:\n  ~a::Backend& backend_;\n};\n\n}  // namespace rivet_app\n"
           backend-namespace)))

(define (kotlin-enum-definition enum)
  (define name (record-native-name (schema-enum-name enum) kotlin-id))
  (string-append
   (format "enum class ~a(val wireName: String) {\n" name)
   (apply string-append
          (for/list ([case (in-list (schema-enum-cases enum))])
            (format "    ~a(~a),\n"
                    (kotlin-id case)
                    (kotlin-string-literal (symbol->string case)))))
   "    ;\n\n"
   (format "    companion object {\n        fun fromWireName(name: String): ~a =\n            entries.firstOrNull { it.wireName == name }\n                ?: throw RivetGeneratedException(\"Rivet result type mismatch: ~a\")\n    }\n}\n\n"
           name name)))

(define (kotlin-record-definition record)
  (define name (record-native-name (schema-record-name record) kotlin-id))
  (define fields (map kotlin-id (schema-record-field-names record)))
  (define types (schema-record-field-types record))
  (format "data class ~a(\n~a)\n\n"
          name
          (string-join
           (for/list ([field (in-list fields)] [type (in-list types)])
             (format "    val ~a: ~a," field (kotlin-type type)))
           "\n")))

(define (kotlin-encoder type)
  (define key (type-key type))
  (define record (schema-record-for type))
  (define enum (schema-enum-for type))
  (cond
    [record
     (define fields (map kotlin-id (schema-record-field-names record)))
     (define types (schema-record-field-types record))
     (define encoded
       (string-join
        (for/list ([field (in-list fields)] [field-type (in-list types)])
          (format "encode_~a(v.~a)" (type-key field-type) field))
        ", "))
     (format "private fun encode_~a(v: ~a): RivetValue =\n    RivetValue.ListValue(listOf(~a))\n"
             key (kotlin-type type) encoded)]
    [enum
     (format "private fun encode_~a(v: ~a): RivetValue =\n    RivetValue.StringValue(v.wireName)\n"
             key (kotlin-type type))]
    [else
     (match type
       ['String (format "private fun encode_~a(v: String): RivetValue =\n    RivetValue.StringValue(v)\n" key)]
       ['Int64 (format "private fun encode_~a(v: Long): RivetValue =\n    RivetValue.Int64(v)\n" key)]
       ['Bool (format "private fun encode_~a(v: Boolean): RivetValue =\n    RivetValue.Bool(v)\n" key)]
       ['Bytes (format "private fun encode_~a(v: ByteArray): RivetValue =\n    RivetValue.Bytes(v)\n" key)]
       ['Void (format "private fun encode_~a(v: Unit): RivetValue =\n    RivetValue.Null\n" key)]
       ['Any (format "private fun encode_~a(v: RivetValue): RivetValue = v\n" key)]
       [(list 'List inner)
        (format "private fun encode_~a(v: ~a): RivetValue =\n    RivetValue.ListValue(v.map { encode_~a(it) })\n"
                key (kotlin-type type) (type-key inner))]
       [(list 'Optional inner)
        (format "private fun encode_~a(v: ~a): RivetValue =\n    v?.let { encode_~a(it) } ?: RivetValue.Null\n"
                key (kotlin-type type) (type-key inner))])]))

(define (kotlin-decoder type)
  (define key (type-key type))
  (define mismatch
    (kotlin-string-literal
     (string-append "Rivet result type mismatch: " (format "~s" type))))
  (define record (schema-record-for type))
  (define enum (schema-enum-for type))
  (cond
    [record
     (define name (kotlin-type type))
     (define fields (map kotlin-id (schema-record-field-names record)))
     (define types (schema-record-field-types record))
     (format
      "private fun decode_~a(v: RivetValue): ~a {\n    val xs = v as? RivetValue.ListValue ?: throw RivetGeneratedException(~a)\n    if (xs.values.size != ~a) throw RivetGeneratedException(~a)\n    return ~a(\n~a    )\n}\n"
      key name mismatch (length types) mismatch name
      (apply
       string-append
       (for/list ([field (in-list fields)]
                  [field-type (in-list types)]
                  [index (in-naturals)])
         (format "        ~a = decode_~a(xs.values[~a]),\n"
                 field (type-key field-type) index))))]
    [enum
     (format "private fun decode_~a(v: RivetValue): ~a {\n    val raw = v as? RivetValue.StringValue ?: throw RivetGeneratedException(~a)\n    return ~a.fromWireName(raw.value)\n}\n"
             key (kotlin-type type) mismatch (kotlin-type type))]
    [else
     (match type
       ['String (format "private fun decode_~a(v: RivetValue): String =\n    (v as? RivetValue.StringValue)?.value ?: throw RivetGeneratedException(~a)\n" key mismatch)]
       ['Int64 (format "private fun decode_~a(v: RivetValue): Long =\n    (v as? RivetValue.Int64)?.value ?: throw RivetGeneratedException(~a)\n" key mismatch)]
       ['Bool (format "private fun decode_~a(v: RivetValue): Boolean =\n    (v as? RivetValue.Bool)?.value ?: throw RivetGeneratedException(~a)\n" key mismatch)]
       ['Bytes (format "private fun decode_~a(v: RivetValue): ByteArray =\n    (v as? RivetValue.Bytes)?.toByteArray() ?: throw RivetGeneratedException(~a)\n" key mismatch)]
       ['Void (format "private fun decode_~a(v: RivetValue) {\n    if (v != RivetValue.Null) throw RivetGeneratedException(~a)\n}\n" key mismatch)]
       ['Any (format "private fun decode_~a(v: RivetValue): RivetValue = v\n" key)]
       [(list 'List inner)
        (format "private fun decode_~a(v: RivetValue): ~a =\n    (v as? RivetValue.ListValue)?.values?.map { decode_~a(it) } ?: throw RivetGeneratedException(~a)\n"
                key (kotlin-type type) (type-key inner) mismatch)]
       [(list 'Optional inner)
        (format "private fun decode_~a(v: RivetValue): ~a {\n    if (v == RivetValue.Null) return null\n    return decode_~a(v)\n}\n"
                key (kotlin-type type) (type-key inner))])]))

(define (kotlin-rpc-method info)
  (define names (map kotlin-id (schema-rpc-arg-names info)))
  (define types (schema-rpc-arg-types info))
  (define result (schema-rpc-result-type info))
  (define params
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "~a: ~a" name (kotlin-type type)))
     ", "))
  (define call
    (if (null? names)
        (format "client.call(~a)" (kotlin-string-literal (symbol->string (schema-rpc-name info))))
        (format "client.call(~a, listOf(~a))"
                (kotlin-string-literal (symbol->string (schema-rpc-name info)))
                (string-join
                 (for/list ([name (in-list names)] [type (in-list types)])
                   (format "encode_~a(~a)" (type-key type) name))
                 ", "))))
  (format
   "    suspend fun ~a(~a): ~a {\n        val result = ~a\n        return decode_~a(result)\n    }\n"
   (kotlin-id (schema-rpc-name info)) params (kotlin-type result)
   call (type-key result)))

(define (kotlin-state-methods state)
  (define raw-name (symbol->string (schema-state-name state)))
  (define suffix (upper-first (kotlin-id raw-name)))
  (define type (schema-state-type state))
  (format
   "    suspend fun get~a(): ~a {\n        val result = client.getState(~a)\n        return decode_~a(result)\n    }\n\n    suspend fun set~a(value: ~a): ~a {\n        val result = client.setState(~a, encode_~a(value))\n        return decode_~a(result)\n    }\n"
   suffix (kotlin-type type) (kotlin-string-literal raw-name) (type-key type)
   suffix (kotlin-type type) (kotlin-type type)
   (kotlin-string-literal raw-name) (type-key type) (type-key type)))

(define (generate-kotlin-events events)
  (if (null? events)
      ""
      (string-append
       "sealed interface RivetEvent {\n"
       (apply
        string-append
        (for/list ([event (in-list events)])
          (format "    data class ~a(val value: ~a) : RivetEvent\n"
                  (upper-first (kotlin-id (schema-event-name event)))
                  (kotlin-type (schema-event-type event)))))
       "\n    companion object {\n        fun decode(name: String, value: RivetValue): RivetEvent = when (name) {\n"
       (apply
        string-append
        (for/list ([event (in-list events)])
          (format "            ~a -> ~a(decode_~a(value))\n"
                  (kotlin-string-literal (symbol->string (schema-event-name event)))
                  (upper-first (kotlin-id (schema-event-name event)))
                  (type-key (schema-event-type event)))))
       "            else -> throw RivetGeneratedException(\"unknown Rivet event: \" + name)\n        }\n    }\n}\n\n")))

(define (generate-kotlin rpcs events states records enums module-name entry-name)
  (define types (all-types rpcs events states records enums))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\npackage dev.rivet.generated\n\n"
   "import dev.rivet.runtime.RivetClient\nimport dev.rivet.runtime.RivetValue\n"
   ;; State accessors are package-level extension functions in the Kotlin
   ;; runtime, so generated callers must import them explicitly.
   (if (null? states)
       ""
       "import dev.rivet.runtime.getState\nimport dev.rivet.runtime.setState\n")
   "\n"
   "class RivetGeneratedException(message: String) : IllegalArgumentException(message)\n\n"
   (format "object RivetGeneratedConfig {\n    const val moduleName = ~a\n    const val entryName = ~a\n}\n\n"
           (kotlin-string-literal module-name)
           (kotlin-string-literal entry-name))
   (apply string-append (map kotlin-enum-definition enums))
   (apply string-append (map kotlin-record-definition (order-records records)))
   (apply string-append (map kotlin-encoder types))
   "\n"
   (apply string-append (map kotlin-decoder types))
   "\n"
   (generate-kotlin-events events)
   "class RivetAPI(val client: RivetClient) {\n"
   (apply string-append (map kotlin-rpc-method rpcs))
   (if (null? states) "" "\n    // Shared state\n")
   (apply string-append (map kotlin-state-methods states))
   "}\n"))

(define (write-generated! path content)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display content out))))

(define (generate-clients! project)
  (define backend (project-path project (project-ref project 'backend)))
  (define-values (rpcs events states records enums) (load-schema backend))
  (define module-name (project-ref project 'module))
  (define entry-name (project-ref project 'entry))
  (unless (and (string? module-name) (string? entry-name))
    (error 'generate-clients! "project module and entry settings must be strings"))
  (when (and (null? rpcs) (null? events) (null? states) (null? records) (null? enums))
    (error 'generate-clients! "the backend declares no RPCs, Events, shared states, Records, or Enums"))
  (validate-native-identifiers! rpcs events states records enums)
  (parameterize ([current-records records]
                 [current-enums enums])
    (write-generated!
     (project-path project "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")
     (generate-swift rpcs events states records enums module-name entry-name))
    (write-generated!
     (project-path project "windows" "GeneratedBackend.hpp")
     (generate-cpp rpcs events states records enums module-name entry-name "rivet::windows"))
    (define linux-host (project-path project "linux"))
    (when (directory-exists? linux-host)
      (write-generated!
       (build-path linux-host "GeneratedBackend.hpp")
       (generate-cpp rpcs events states records enums module-name entry-name
                     "rivet::linux_runtime")))
    ;; Android consumes the typed client from the shared generated tree until
    ;; generated Compose projects exist; the package layout keeps the file
    ;; drop-in for Gradle source sets.
    (write-generated!
     (project-path project ".rivet" "generated" "kotlin" "dev" "rivet"
                   "generated" "GeneratedBackend.kt")
     (generate-kotlin rpcs events states records enums module-name entry-name)))
  ;; Preserve the historical first two result positions for callers that
  ;; inspect codegen output programmatically; Events, Records, and Enums follow.
  (list rpcs states events records enums))
