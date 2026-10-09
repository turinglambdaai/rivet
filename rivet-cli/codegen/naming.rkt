#lang racket/base

(require racket/list
         racket/string
         "model.rkt")

(provide swift-id
         cpp-id
         kotlin-id
         swift-string-literal
         cpp-string-literal
         kotlin-string-literal
         cpp-event-type-name
         swift-device-request-name
         validate-native-identifiers!)

(define swift-keywords
  '("Any" "Self" "actor" "as" "associatedtype" "async" "await" "break"
    "case" "catch" "class" "continue" "default" "defer" "deinit" "do"
    "else" "enum" "extension" "fallthrough" "false" "fileprivate" "for"
    "func" "guard" "if" "import" "in" "init" "inout" "internal" "is"
    "let" "nil" "nonisolated" "open" "operator" "precedencegroup"
    "private" "protocol" "public" "repeat" "rethrows" "return" "self"
    "static" "struct" "subscript" "super" "switch" "throw" "throws"
    "true" "try" "typealias" "var" "where" "while"))

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
       (format "~a native API name collision: ~a and ~a both generate ~a"
               language previous source generated)
       "language" language
       "generated name" generated
       "first declaration" previous
       "second declaration" source))
    (hash-set! seen generated source)))

(define (cpp-event-type-name event)
  (string-append (upper-first (cpp-id (schema-event-name event))) "Event"))

(define (validate-native-identifiers! rpcs events states records enums [device-rpcs '()])
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
    (list (cons "RivetTypes" "generated Swift schema namespace"))
    (for/list ([record (in-list records)])
      (cons (record-native-name (schema-record-name record) swift-id)
            (format "Record ~a" (schema-record-name record))))
    (for/list ([enum (in-list enums)])
      (cons (record-native-name (schema-enum-name enum) swift-id)
            (format "Enum ~a" (schema-enum-name enum))))
    (if (null? device-rpcs)
        '()
        (append
         (list (cons "RivetDeviceRequests" "generated device request namespace"))
         (if (ormap (lambda (rpc) (eq? (schema-rpc-result-type rpc) 'Void))
                    device-rpcs)
             (list (cons "RivetDeviceUnit" "generated device Void response"))
             '())))))

  (check-unique-native-names!
   "Swift device request types"
   (for/list ([rpc (in-list device-rpcs)])
     (cons (swift-device-request-name rpc)
           (format "device RPC ~a" (schema-rpc-name rpc)))))
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
       (define name (swift-id (schema-state-name state)))
       (list (cons (string-append "get_" name)
                   (format "State getter ~a" (schema-state-name state)))
             (cons (string-append "set_" name)
                   (format "State setter ~a" (schema-state-name state))))))))

  ;; Kotlin mirrors the Swift member surface: RPC methods plus get_/set_
  ;; accessors sharing the RPC snake_case convention. RivetAPI also owns a
  ;; `client` property.
  (check-unique-native-names!
   "Kotlin API"
   (append
    (list (cons "client" "RivetAPI constructor property"))
    (for/list ([info (in-list rpcs)])
      (cons (kotlin-id (schema-rpc-name info))
            (format "RPC ~a" (schema-rpc-name info))))
    (append*
     (for/list ([state (in-list states)])
       (define name (kotlin-id (schema-state-name state)))
       (list (cons (string-append "get_" name)
                   (format "State getter ~a" (schema-state-name state)))
             (cons (string-append "set_" name)
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

(define (swift-device-request-name rpc)
  (define normalized (swift-id (schema-rpc-name rpc)))
  (define words (filter (lambda (word) (not (string=? word "")))
                        (regexp-split #rx"_+" normalized)))
  (define camel (apply string-append (map upper-first words)))
  (cond
    [(string=? camel "") normalized]
    [(string-prefix? normalized "_") (string-append "_" camel)]
    [else camel]))
