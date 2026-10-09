#lang racket/base

(require racket/list
         racket/match
         racket/string
         "model.rkt"
         "naming.rkt"
         "type-graph.rkt")

(provide generate-kotlin)

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
  ;; Match the RPC surface: Kotlin identifiers stay snake_case end to end, so
  ;; accessors are get_<state>/set_<state> rather than a camelCase get prefix
  ;; glued onto a snake body (getRepo_root).
  (define name (kotlin-id raw-name))
  (define type (schema-state-type state))
  (format
   "    suspend fun get_~a(): ~a {\n        val result = client.getState(~a)\n        return decode_~a(result)\n    }\n\n    suspend fun set_~a(value: ~a): ~a {\n        val result = client.setState(~a, encode_~a(value))\n        return decode_~a(result)\n    }\n"
   name (kotlin-type type) (kotlin-string-literal raw-name) (type-key type)
   name (kotlin-type type) (kotlin-type type)
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

(define (generate-kotlin rpcs events states records enums
                         module-name entry-name display-name version build
                         identifier release-channel)
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
   (format "object RivetGeneratedConfig {\n    const val moduleName = ~a\n    const val entryName = ~a\n    const val displayName = ~a\n    const val version = ~a\n    const val build: Long = ~aL\n    const val identifier = ~a\n    const val releaseChannel = ~a\n}\n\n"
           (kotlin-string-literal module-name)
           (kotlin-string-literal entry-name)
           (kotlin-string-literal display-name)
           (kotlin-string-literal version)
           build
           (kotlin-string-literal identifier)
           (kotlin-string-literal release-channel))
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
