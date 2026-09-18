#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "project.rkt")

(provide generate-clients!)

(struct schema-rpc (name arg-names arg-types result-type) #:transparent)

(define (load-rpc-schema backend)
  (define ns (make-base-namespace))
  (parameterize ([current-namespace ns])
    (dynamic-require backend #f)
    (define get-rpcs (dynamic-require 'rivet/backend 'registered-rpcs))
    (define info-name (dynamic-require 'rivet/backend 'rpc-info-name))
    (define info-arg-names (dynamic-require 'rivet/backend 'rpc-info-arg-names))
    (define info-arg-types (dynamic-require 'rivet/backend 'rpc-info-arg-types))
    (define info-result-type (dynamic-require 'rivet/backend 'rpc-info-result-type))
    (for/list ([info (in-list (get-rpcs))])
      (schema-rpc (info-name info)
                  (info-arg-names info)
                  (info-arg-types info)
                  (info-result-type info)))))

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

(define (nested-types type)
  (match type
    [(list (or 'List 'Optional) inner) (cons type (nested-types inner))]
    [_ (list type)]))

(define (all-types infos)
  (remove-duplicates
   (append*
    (for/list ([info (in-list infos)])
      (append*
       (map nested-types
            (append (schema-rpc-arg-types info)
                    (list (schema-rpc-result-type info)))))))
   equal?))

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
    [_ (error 'generate-clients! "unsupported Swift type: ~e" type)]))

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
    [_ (error 'generate-clients! "unsupported C++ type: ~e" type)]))

(define (swift-encoder type)
  (define key (type-key type))
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
             key (swift-type type) (type-key inner))]))

(define (swift-decoder type)
  (define key (type-key type))
  (define expected (format "~s" type))
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
             key (swift-type type) (type-key inner))]))

(define (swift-method info)
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

(define (generate-swift infos module-name entry-name)
  (define types (all-types infos))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\nimport Foundation\nimport RivetRuntime\n\n"
   "public enum RivetGeneratedError: Error { case typeMismatch(String) }\n"
   (format "public enum RivetGeneratedConfig { public static let moduleName = ~s; public static let entryName = ~s }\n\n" module-name entry-name)
   (apply string-append (map swift-encoder types))
   "\n"
   (apply string-append (map swift-decoder types))
   "\npublic struct RivetAPI: Sendable {\n    public let client: RivetClient\n    public init(client: RivetClient) { self.client = client }\n\n"
   (apply string-append (map swift-method infos))
   "}\n"))

(define (cpp-encoder type)
  (define key (type-key type))
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
             key (cpp-type type) (type-key inner))]))

(define (cpp-decoder type)
  (define key (type-key type))
  (define error-text (string-append "Rivet result type mismatch: " (format "~s" type)))
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
             (cpp-type type) key (type-key inner))]))

(define (cpp-method info)
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
  (define result (cpp-type result-type))
  (define decode
    (if (eq? result-type 'Void)
        (format "detail::decode_~a(raw.get());" (type-key result-type))
        (format "return detail::decode_~a(raw.get());" (type-key result-type))))
  (format
   "  std::future<~a> ~a(~a) { auto raw = backend_.call(~s, rivet::Value::List{~a}); return std::async(std::launch::deferred, [raw = std::move(raw)]() mutable -> ~a { ~a }); }\n"
   result (cpp-id (schema-rpc-name info)) params
   (symbol->string (schema-rpc-name info)) encoded result decode))

(define (generate-cpp infos module-name entry-name)
  (define types (all-types infos))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n#pragma once\n\n#include <cstdint>\n#include <future>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <vector>\n\n#include \"backend.hpp\"\n\nnamespace rivet_app {\n"
   (format "inline constexpr char kModuleName[] = ~s;\ninline constexpr char kEntryName[] = ~s;\n\n" module-name entry-name)
   "namespace detail {\n"
   (apply string-append (map cpp-encoder types))
   "\n"
   (apply string-append (map cpp-decoder types))
   "}  // namespace detail\n\nclass API {\n public:\n  explicit API(rivet::windows::Backend& backend) : backend_(backend) {}\n\n"
   (apply string-append (map cpp-method infos))
   "\n private:\n  rivet::windows::Backend& backend_;\n};\n\n}  // namespace rivet_app\n"))

(define (write-generated! path content)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display content out))))

(define (generate-clients! project)
  (define backend (project-path project (project-ref project 'backend)))
  (define infos (load-rpc-schema backend))
  (define module-name (project-ref project 'module))
  (define entry-name (project-ref project 'entry))
  (unless (and (string? module-name) (string? entry-name))
    (error 'generate-clients! "project module and entry settings must be strings"))
  (when (null? infos)
    (error 'generate-clients! "the backend declares no RPCs"))
  (write-generated!
   (project-path project "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")
   (generate-swift infos module-name entry-name))
  (write-generated!
   (project-path project "windows" "GeneratedBackend.hpp")
   (generate-cpp infos module-name entry-name))
  infos)
