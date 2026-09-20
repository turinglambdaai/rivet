#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "project.rkt")

(provide generate-csharp-client!)

(struct schema-rpc (name arg-names arg-types result-type) #:transparent)
(struct schema-state (name type) #:transparent)
(struct schema-record (name field-names field-types) #:transparent)

(define (load-schema backend)
  (define ns (make-base-namespace))
  (parameterize ([current-namespace ns])
    (dynamic-require backend #f)
    (define get-rpcs (dynamic-require 'rivet/backend 'registered-rpcs))
    (define rpc-name (dynamic-require 'rivet/backend 'rpc-info-name))
    (define rpc-arg-names (dynamic-require 'rivet/backend 'rpc-info-arg-names))
    (define rpc-arg-types (dynamic-require 'rivet/backend 'rpc-info-arg-types))
    (define rpc-result-type (dynamic-require 'rivet/backend 'rpc-info-result-type))
    (define get-states (dynamic-require 'rivet/backend 'registered-states))
    (define state-name (dynamic-require 'rivet/backend 'state-info-name))
    (define state-type (dynamic-require 'rivet/backend 'state-info-type))
    (define get-records (dynamic-require 'rivet/backend 'registered-records))
    (define record-name (dynamic-require 'rivet/backend 'record-info-name))
    (define record-field-names (dynamic-require 'rivet/backend 'record-info-field-names))
    (define record-field-types (dynamic-require 'rivet/backend 'record-info-field-types))
    (values
     (for/list ([info (in-list (get-rpcs))])
       (schema-rpc (rpc-name info)
                   (rpc-arg-names info)
                   (rpc-arg-types info)
                   (rpc-result-type info)))
     (for/list ([info (in-list (get-states))])
       (schema-state (state-name info) (state-type info)))
     (for/list ([info (in-list (get-records))])
       (schema-record (record-name info)
                      (record-field-names info)
                      (record-field-types info))))))

(define current-records (make-parameter '()))

(define (record-for type)
  (and (symbol? type)
       (findf (lambda (record) (eq? (schema-record-name record) type))
              (current-records))))

(define csharp-keywords
  '("abstract" "as" "base" "bool" "break" "byte" "case" "catch" "char"
    "checked" "class" "const" "continue" "decimal" "default" "delegate" "do"
    "double" "else" "enum" "event" "explicit" "extern" "false" "finally"
    "fixed" "float" "for" "foreach" "goto" "if" "implicit" "in" "int"
    "interface" "internal" "is" "lock" "long" "namespace" "new" "null"
    "object" "operator" "out" "override" "params" "private" "protected"
    "public" "readonly" "ref" "return" "sbyte" "sealed" "short" "sizeof"
    "stackalloc" "static" "string" "struct" "switch" "this" "throw" "true"
    "try" "typeof" "uint" "ulong" "unchecked" "unsafe" "ushort" "using"
    "virtual" "void" "volatile" "while" "async" "await" "record" "required"))

(define (identifier-parts value)
  (filter (lambda (part) (not (string=? part "")))
          (regexp-split #px"[^A-Za-z0-9]+"
                        (if (symbol? value) (symbol->string value) value))))

(define (upper-first value)
  (if (zero? (string-length value))
      value
      (string-append (string-upcase (substring value 0 1))
                     (substring value 1))))

(define (lower-first value)
  (if (zero? (string-length value))
      value
      (string-append (string-downcase (substring value 0 1))
                     (substring value 1))))

(define (pascal-id value)
  (define parts (identifier-parts value))
  (define raw (if (null? parts) "Value" (apply string-append (map upper-first parts))))
  (define safe (if (regexp-match? #px"^[0-9]" raw) (string-append "_" raw) raw))
  (if (member (string-downcase safe) csharp-keywords) (string-append "Rivet" safe) safe))

(define (camel-id value)
  (lower-first (pascal-id value)))

(define (type-key type)
  (regexp-replace* #px"[^A-Za-z0-9]+" (format "~s" type) "_"))

(define (value-type? type)
  (memq type '(Int64 Bool)))

(define (cs-type type)
  (match type
    ['String "string"]
    ['Int64 "long"]
    ['Bool "bool"]
    ['Bytes "byte[]"]
    ['Void "void"]
    ['Any "RivetValue"]
    [(list 'List inner) (format "IReadOnlyList<~a>" (cs-type inner))]
    [(list 'Optional inner) (format "~a?" (cs-type inner))]
    [_ (if (record-for type)
           (pascal-id type)
           (error 'generate-csharp-client! "unsupported C# type: ~e" type))]))

(define (type-dependencies type)
  (match type
    [(list (or 'List 'Optional) inner) (list inner)]
    [_
     (define record (record-for type))
     (if record (schema-record-field-types record) '())]))

(define (nested-types type)
  (cons type
        (append*
         (for/list ([dependency (in-list (type-dependencies type))])
           (nested-types dependency)))))

(define (all-types rpcs states records)
  (remove-duplicates
   (append
    (append*
     (for/list ([rpc (in-list rpcs)])
       (append*
        (map nested-types
             (append (schema-rpc-arg-types rpc)
                     (list (schema-rpc-result-type rpc)))))))
    (append*
     (for/list ([state (in-list states)])
       (nested-types (schema-state-type state))))
    (append*
     (for/list ([record (in-list records)])
       (nested-types (schema-record-name record)))))
   equal?))

(define (record-definition record)
  (define fields
    (string-join
     (for/list ([name (in-list (schema-record-field-names record))]
                [type (in-list (schema-record-field-types record))])
       (format "~a ~a" (cs-type type) (pascal-id name)))
     ", "))
  (format "public sealed record ~a(~a);\n"
          (pascal-id (schema-record-name record)) fields))

(define (encoder type)
  (define key (type-key type))
  (define record (record-for type))
  (cond
    [record
     (define encoded
       (string-join
        (for/list ([name (in-list (schema-record-field-names record))]
                   [field-type (in-list (schema-record-field-types record))])
          (format "Encode_~a(value.~a)" (type-key field-type) (pascal-id name)))
        ", "))
     (format "    private static RivetValue Encode_~a(~a value) => RivetValue.List(~a);\n"
             key (cs-type type) encoded)]
    [else
     (match type
       ['String (format "    private static RivetValue Encode_~a(string value) => RivetValue.From(value);\n" key)]
       ['Int64 (format "    private static RivetValue Encode_~a(long value) => RivetValue.From(value);\n" key)]
       ['Bool (format "    private static RivetValue Encode_~a(bool value) => RivetValue.From(value);\n" key)]
       ['Bytes (format "    private static RivetValue Encode_~a(byte[] value) => RivetValue.From(value);\n" key)]
       ['Void (format "    private static RivetValue Encode_~a() => RivetValue.Null;\n" key)]
       ['Any (format "    private static RivetValue Encode_~a(RivetValue value) => value;\n" key)]
       [(list 'List inner)
        (format "    private static RivetValue Encode_~a(~a value) => RivetValue.From(value.Select(Encode_~a).ToArray());\n"
                key (cs-type type) (type-key inner))]
       [(list 'Optional inner)
        (if (value-type? inner)
            (format "    private static RivetValue Encode_~a(~a value) => value.HasValue ? Encode_~a(value.Value) : RivetValue.Null;\n"
                    key (cs-type type) (type-key inner))
            (format "    private static RivetValue Encode_~a(~a value) => value is null ? RivetValue.Null : Encode_~a(value);\n"
                    key (cs-type type) (type-key inner)))])]))

(define (decoder type)
  (define key (type-key type))
  (define record (record-for type))
  (cond
    [record
     (define decoded
       (string-join
        (for/list ([field-type (in-list (schema-record-field-types record))]
                   [index (in-naturals)])
          (format "Decode_~a(items[~a])" (type-key field-type) index))
        ", "))
     (format
      (string-append
       "    private static ~a Decode_~a(RivetValue value)\n"
       "    {\n"
       "        var items = value.AsList();\n"
       "        if (items.Count != ~a) throw new InvalidDataException(\"Rivet Record ~a field count mismatch.\");\n"
       "        return new ~a(~a);\n"
       "    }\n")
      (cs-type type) key (length (schema-record-field-names record))
      (pascal-id (schema-record-name record)) (cs-type type) decoded)]
    [else
     (match type
       ['String (format "    private static string Decode_~a(RivetValue value) => value.AsString();\n" key)]
       ['Int64 (format "    private static long Decode_~a(RivetValue value) => value.AsInt64();\n" key)]
       ['Bool (format "    private static bool Decode_~a(RivetValue value) => value.AsBool();\n" key)]
       ['Bytes (format "    private static byte[] Decode_~a(RivetValue value) => value.AsBytes();\n" key)]
       ['Void
        (format
         (string-append
          "    private static void Decode_~a(RivetValue value)\n"
          "    {\n"
          "        if (value is not RivetValue.NullValue) throw new InvalidDataException(\"Expected Rivet Void/null.\");\n"
          "    }\n") key)]
       ['Any (format "    private static RivetValue Decode_~a(RivetValue value) => value;\n" key)]
       [(list 'List inner)
        (format "    private static ~a Decode_~a(RivetValue value) => value.AsList().Select(Decode_~a).ToArray();\n"
                (cs-type type) key (type-key inner))]
       [(list 'Optional inner)
        (format "    private static ~a Decode_~a(RivetValue value) => value is RivetValue.NullValue ? null : Decode_~a(value);\n"
                (cs-type type) key (type-key inner))])]))

(define (rpc-method rpc)
  (define names (map camel-id (schema-rpc-arg-names rpc)))
  (define types (schema-rpc-arg-types rpc))
  (define result (schema-rpc-result-type rpc))
  (define params
    (append
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "~a ~a" (cs-type type) name))
     (list "CancellationToken cancellationToken = default")))
  (define encoded
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "Encode_~a(~a)" (type-key type) name))
     ", "))
  (define method-name (string-append (pascal-id (schema-rpc-name rpc)) "Async"))
  (if (eq? result 'Void)
      (format
       (string-append
        "    public async Task ~a(~a)\n"
        "    {\n"
        "        var result = await _client.CallAsync(~s, new RivetValue[] { ~a }, cancellationToken).ConfigureAwait(false);\n"
        "        Decode_~a(result);\n"
        "    }\n")
       method-name (string-join params ", ")
       (symbol->string (schema-rpc-name rpc)) encoded (type-key result))
      (format
       (string-append
        "    public async Task<~a> ~a(~a)\n"
        "    {\n"
        "        var result = await _client.CallAsync(~s, new RivetValue[] { ~a }, cancellationToken).ConfigureAwait(false);\n"
        "        return Decode_~a(result);\n"
        "    }\n")
       (cs-type result) method-name (string-join params ", ")
       (symbol->string (schema-rpc-name rpc)) encoded (type-key result))))

(define (state-methods state)
  (define raw-name (symbol->string (schema-state-name state)))
  (define suffix (pascal-id raw-name))
  (define type (schema-state-type state))
  (format
   (string-append
    "    public async Task<~a> Get~aAsync(CancellationToken cancellationToken = default)\n"
    "    {\n"
    "        var result = await _client.GetStateAsync(~s, cancellationToken).ConfigureAwait(false);\n"
    "        return Decode_~a(result);\n"
    "    }\n"
    "    public async Task<~a> Set~aAsync(~a value, CancellationToken cancellationToken = default)\n"
    "    {\n"
    "        var result = await _client.SetStateAsync(~s, Encode_~a(value), cancellationToken).ConfigureAwait(false);\n"
    "        return Decode_~a(result);\n"
    "    }\n")
   (cs-type type) suffix raw-name (type-key type)
   (cs-type type) suffix (cs-type type) raw-name (type-key type) (type-key type)))

(define (generate-source rpcs states records project-name)
  (parameterize ([current-records records])
    (define types (all-types rpcs states records))
    (define namespace-name (string-append (pascal-id project-name) ".RivetGenerated"))
    (string-append
     "// Generated by Rivet. Do not edit by hand.\n"
     "using Rivet.Runtime;\n\n"
     (format "namespace ~a;\n\n" namespace-name)
     (apply string-append (map (lambda (record) (string-append (record-definition record) "\n")) records))
     "public sealed class RivetAPI\n{\n"
     "    private readonly IRivetClient _client;\n"
     "    public RivetAPI(IRivetClient client) => _client = client ?? throw new ArgumentNullException(nameof(client));\n\n"
     (apply string-append (map encoder types))
     "\n"
     (apply string-append (map decoder types))
     "\n"
     (apply string-append (map rpc-method rpcs))
     (if (null? states) "" "\n    // Shared state\n")
     (apply string-append (map state-methods states))
     "}\n")))

(define (generate-csharp-client! project)
  (define backend (project-path project (project-ref project 'backend)))
  (define-values (rpcs states records) (load-schema backend))
  (define project-name (project-ref project 'name))
  (unless (string? project-name)
    (error 'generate-csharp-client! "project name must be a string"))
  (define output (project-path project "dotnet" "GeneratedBackend.cs"))
  (make-parent-directory* output)
  (call-with-output-file output #:exists 'truncate/replace
    (lambda (out)
      (display (generate-source rpcs states records project-name) out)))
  output)
