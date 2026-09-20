#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "project.rkt")

(provide generate-clients!)

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

(define (swift-id value) (identifier value swift-keywords))
(define (cpp-id value) (identifier value cpp-keywords))

(define (upper-first value)
  (if (zero? (string-length value))
      value
      (string-append (string-upcase (substring value 0 1))
                     (substring value 1))))

(define current-records (make-parameter '()))

(define (schema-record-for type)
  (and (symbol? type)
       (findf (lambda (record) (eq? (schema-record-name record) type))
              (current-records))))

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

(define (all-types rpcs states records)
  (define raw
    (append
     (append*
      (for/list ([info (in-list rpcs)])
        (append*
         (map nested-types
              (append (schema-rpc-arg-types info)
                      (list (schema-rpc-result-type info)))))))
     (append*
      (for/list ([state (in-list states)])
        (nested-types (schema-state-type state))))
     (append*
      (for/list ([record (in-list records)])
        (nested-types (schema-record-name record))))))
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
     (if (schema-record-for type)
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
     (if (schema-record-for type)
         (record-native-name type cpp-id)
         (error 'generate-clients! "unsupported C++ type: ~e" type))]))

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

(define (swift-encoder type)
  (define key (type-key type))
  (define record (schema-record-for type))
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
  (define expected (format "~s" type))
  (define record (schema-record-for type))
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
     (format "private func decode_~a(_ v: RivetValue) throws -> ~a { guard case .list(let xs) = v, xs.count == ~a else { throw RivetGeneratedError.typeMismatch(~s) }; return ~a(~a) }\n"
             key (swift-type type) (length fields) expected (swift-type type) decoded)]
    [else
     (match type
       ['String (format "private func decode_~a(_ v: RivetValue) throws -> String { guard case .string(let x) = v else { throw RivetGeneratedError.typeMismatch(~s) }; return x }\n" key expected)]
       ['Int64 (format "private func decode_~a(_ v: RivetValue) throws -> Int64 { guard case .int64(let x) = v else { throw RivetGeneratedError.typeMismatch(~s) }; return x }\n" key expected)]
       ['Bool (format "private func decode_~a(_ v: RivetValue) throws -> Bool { guard case .bool(let x) = v else { throw RivetGeneratedError.typeMismatch(~s) }; return x }\n" key expected)]
       ['Bytes (format "private func decode_~a(_ v: RivetValue) throws -> Data { guard case .bytes(let x) = v else { throw RivetGeneratedError.typeMismatch(~s) }; return x }\n" key expected)]
       ['Void (format "private func decode_~a(_ v: RivetValue) throws -> Void { guard case .null = v else { throw RivetGeneratedError.typeMismatch(~s) } }\n" key expected)]
       ['Any (format "private func decode_~a(_ v: RivetValue) throws -> RivetValue { v }\n" key)]
       [(list 'List inner)
        (format "private func decode_~a(_ v: RivetValue) throws -> ~a { guard case .list(let xs) = v else { throw RivetGeneratedError.typeMismatch(~s) }; return try xs.map(decode_~a) }\n"
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
   "    public func ~a(~a) async throws -> ~a {\n        let result = try await client.call(~s, arguments: [~a])\n        return try decode_~a(result)\n    }\n"
   (swift-id (schema-rpc-name info)) params (swift-type result)
   (symbol->string (schema-rpc-name info)) encoded (type-key result)))

(define (swift-state-methods state)
  (define raw-name (symbol->string (schema-state-name state)))
  (define suffix (upper-first (swift-id raw-name)))
  (define type (schema-state-type state))
  (format
   "    public func get~a() async throws -> ~a {\n        let result = try await client.getState(~s)\n        return try decode_~a(result)\n    }\n    @discardableResult\n    public func set~a(_ value: ~a) async throws -> ~a {\n        let result = try await client.setState(~s, value: encode_~a(value))\n        return try decode_~a(result)\n    }\n"
   suffix (swift-type type) raw-name (type-key type)
   suffix (swift-type type) (swift-type type) raw-name (type-key type) (type-key type)))

(define (generate-swift rpcs states records module-name entry-name)
  (define types (all-types rpcs states records))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\nimport Foundation\nimport RivetRuntime\n\n"
   "public enum RivetGeneratedError: Error { case typeMismatch(String) }\n"
   (format "public enum RivetGeneratedConfig { public static let moduleName = ~s; public static let entryName = ~s }\n\n" module-name entry-name)
   (apply string-append (map swift-record-definition (order-records records)))
   (apply string-append (map swift-encoder types))
   "\n"
   (apply string-append (map swift-decoder types))
   "\npublic struct RivetAPI: Sendable {\n    public let client: RivetClient\n    public init(client: RivetClient) { self.client = client }\n\n"
   (apply string-append (map swift-rpc-method rpcs))
   (if (null? states) "" "\n    // Shared state\n")
   (apply string-append (map swift-state-methods states))
   "}\n"))

(define (cpp-encoder type)
  (define key (type-key type))
  (define record (schema-record-for type))
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
  (define error-text (string-append "Rivet result type mismatch: " (format "~s" type)))
  (define record (schema-record-for type))
  (cond
    [record
     (define types (schema-record-field-types record))
     (define decoded
       (string-join
        (for/list ([field-type (in-list types)] [index (in-naturals)])
          (format "decode_~a((*p)[~a])" (type-key field-type) index))
        ", "))
     (format "inline ~a decode_~a(rivet::Value const& v) { auto p = std::get_if<rivet::Value::List>(&v.data); if (!p || p->size() != ~a) throw std::runtime_error(~s); return ~a{~a}; }\n"
             (cpp-type type) key (length types) error-text (cpp-type type) decoded)]
    [else
     (match type
       ['String (format "inline std::string decode_~a(rivet::Value const& v) { if (auto p = std::get_if<std::string>(&v.data)) return *p; throw std::runtime_error(~s); }\n" key error-text)]
       ['Int64 (format "inline std::int64_t decode_~a(rivet::Value const& v) { if (auto p = std::get_if<std::int64_t>(&v.data)) return *p; throw std::runtime_error(~s); }\n" key error-text)]
       ['Bool (format "inline bool decode_~a(rivet::Value const& v) { if (auto p = std::get_if<bool>(&v.data)) return *p; throw std::runtime_error(~s); }\n" key error-text)]
       ['Bytes (format "inline rivet::Bytes decode_~a(rivet::Value const& v) { if (auto p = std::get_if<rivet::Bytes>(&v.data)) return *p; throw std::runtime_error(~s); }\n" key error-text)]
       ['Void (format "inline void decode_~a(rivet::Value const& v) { if (!std::holds_alternative<std::monostate>(v.data)) throw std::runtime_error(~s); }\n" key error-text)]
       ['Any (format "inline rivet::Value decode_~a(rivet::Value const& v) { return v; }\n" key)]
       [(list 'List inner)
        (format "inline ~a decode_~a(rivet::Value const& v) { auto p = std::get_if<rivet::Value::List>(&v.data); if (!p) throw std::runtime_error(~s); ~a r; r.reserve(p->size()); for (auto const& x : *p) r.push_back(decode_~a(x)); return r; }\n"
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

(define (cpp-rpc-method info)
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
  (format
   "  std::future<~a> ~a(~a) { ~a }\n"
   (cpp-type result-type)
   (cpp-id (schema-rpc-name info))
   params
   (cpp-future result-type
               (format "backend_.call(~s, rivet::Value::List{~a})"
                       (symbol->string (schema-rpc-name info))
                       encoded))))

(define (cpp-state-methods state)
  (define name (cpp-id (schema-state-name state)))
  (define raw-name (symbol->string (schema-state-name state)))
  (define type (schema-state-type state))
  (format
   "  std::future<~a> get_~a() { ~a }\n  std::future<~a> set_~a(~a value) { ~a }\n"
   (cpp-type type) name
   (cpp-future type (format "backend_.get_state(~s)" raw-name))
   (cpp-type type) name (cpp-type type)
   (cpp-future type
               (format "backend_.set_state(~s, detail::encode_~a(value))"
                       raw-name (type-key type)))))

(define (generate-cpp rpcs states records module-name entry-name)
  (define types (all-types rpcs states records))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n#pragma once\n\n#include <cstdint>\n#include <future>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <vector>\n\n#include \"backend.hpp\"\n\nnamespace rivet_app {\n"
   (format "inline constexpr char kModuleName[] = ~s;\ninline constexpr char kEntryName[] = ~s;\n\n" module-name entry-name)
   (apply string-append (map cpp-record-definition (order-records records)))
   "namespace detail {\n"
   (apply string-append (map cpp-encoder types))
   "\n"
   (apply string-append (map cpp-decoder types))
   "}  // namespace detail\n\nclass API {\n public:\n  explicit API(rivet::windows::Backend& backend) : backend_(backend) {}\n\n"
   (apply string-append (map cpp-rpc-method rpcs))
   (if (null? states) "" "\n  // Shared state\n")
   (apply string-append (map cpp-state-methods states))
   "\n private:\n  rivet::windows::Backend& backend_;\n};\n\n}  // namespace rivet_app\n"))

(define (write-generated! path content)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display content out))))

(define (generate-clients! project)
  (define backend (project-path project (project-ref project 'backend)))
  (define-values (rpcs states records) (load-schema backend))
  (define module-name (project-ref project 'module))
  (define entry-name (project-ref project 'entry))
  (unless (and (string? module-name) (string? entry-name))
    (error 'generate-clients! "project module and entry settings must be strings"))
  (when (and (null? rpcs) (null? states))
    (error 'generate-clients! "the backend declares no RPCs or shared states"))
  (parameterize ([current-records records])
    (write-generated!
     (project-path project "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")
     (generate-swift rpcs states records module-name entry-name))
    (write-generated!
     (project-path project "windows" "GeneratedBackend.hpp")
     (generate-cpp rpcs states records module-name entry-name)))
  (list rpcs states records))
