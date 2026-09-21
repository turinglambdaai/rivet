#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "project.rkt")

(provide generate-clients!)

(struct schema-rpc (name arg-names arg-types result-type) #:transparent)
(struct schema-event (name type) #:transparent)
(struct schema-state (name type) #:transparent)

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
    (values
     (for/list ([info (in-list (get-rpcs))])
       (schema-rpc (rpc-name info)
                   (rpc-arg-names info)
                   (rpc-arg-types info)
                   (rpc-result-type info)))
     (for/list ([info (in-list (get-events))])
       (schema-event (event-name info) (event-type info)))
     (for/list ([info (in-list (get-states))])
       (schema-state (state-name info) (state-type info))))))

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

(define (validate-native-identifiers! rpcs events states)
  (for ([info (in-list rpcs)])
    (define rpc-label (format "RPC ~a" (schema-rpc-name info)))
    (check-unique-native-names!
     "Swift arguments"
     (for/list ([name (in-list (schema-rpc-arg-names info))])
       (cons (swift-id name) (format "~a argument ~a" rpc-label name))))
    (check-unique-native-names!
     "C++ arguments"
     (for/list ([name (in-list (schema-rpc-arg-names info))])
       (cons (cpp-id name) (format "~a argument ~a" rpc-label name)))))

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

  (check-unique-native-names!
   "C++ API"
   (append
    (for/list ([info (in-list rpcs)])
      (cons (cpp-id (schema-rpc-name info))
            (format "RPC ~a" (schema-rpc-name info))))
    (append*
     (for/list ([state (in-list states)])
       (define name (cpp-id (schema-state-name state)))
       (list (cons (string-append "get_" name)
                   (format "State getter ~a" (schema-state-name state)))
             (cons (string-append "set_" name)
                   (format "State setter ~a" (schema-state-name state))))))))

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

(define (nested-types type)
  (match type
    [(list (or 'List 'Optional) inner) (cons type (nested-types inner))]
    [_ (list type)]))

(define (all-types rpcs events states)
  (remove-duplicates
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
       (nested-types (schema-state-type state)))))
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
  (define expected (swift-string-literal (format "~s" type)))
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
             key (swift-type type) (type-key inner))]))

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

(define (generate-swift rpcs events states module-name entry-name)
  (define types (all-types rpcs events states))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\nimport Foundation\nimport RivetRuntime\n\n"
   "public enum RivetGeneratedError: Error { case typeMismatch(String); case unknownEvent(String) }\n"
   (format "public enum RivetGeneratedConfig { public static let moduleName = ~a; public static let entryName = ~a }\n\n"
           (swift-string-literal module-name)
           (swift-string-literal entry-name))
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
  (define error-text
    (cpp-string-literal
     (string-append "Rivet result type mismatch: " (format "~s" type))))
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
             (cpp-type type) key (type-key inner))]))

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
               (format "backend_.call(~a, rivet::Value::List{~a})"
                       (cpp-string-literal (symbol->string (schema-rpc-name info)))
                       encoded))))

(define (cpp-state-methods state)
  (define name (cpp-id (schema-state-name state)))
  (define raw-name (symbol->string (schema-state-name state)))
  (define type (schema-state-type state))
  (format
   "  std::future<~a> get_~a() { ~a }\n  std::future<~a> set_~a(~a value) { ~a }\n"
   (cpp-type type) name
   (cpp-future type (format "backend_.get_state(~a)" (cpp-string-literal raw-name)))
   (cpp-type type) name (cpp-type type)
   (cpp-future type
               (format "backend_.set_state(~a, detail::encode_~a(value))"
                       (cpp-string-literal raw-name) (type-key type)))))

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

(define (generate-cpp rpcs events states module-name entry-name)
  (define types (all-types rpcs events states))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n#pragma once\n\n#include <cstdint>\n#include <future>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <variant>\n#include <vector>\n\n#include \"backend.hpp\"\n\nnamespace rivet_app {\n"
   (format "inline constexpr char kModuleName[] = ~a;\ninline constexpr char kEntryName[] = ~a;\n\n"
           (cpp-string-literal module-name)
           (cpp-string-literal entry-name))
   "namespace detail {\n"
   (apply string-append (map cpp-encoder types))
   "\n"
   (apply string-append (map cpp-decoder types))
   "}  // namespace detail\n\n"
   (generate-cpp-events events)
   "class API {\n public:\n  explicit API(rivet::windows::Backend& backend) : backend_(backend) {}\n\n"
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
  (define-values (rpcs events states) (load-schema backend))
  (define module-name (project-ref project 'module))
  (define entry-name (project-ref project 'entry))
  (unless (and (string? module-name) (string? entry-name))
    (error 'generate-clients! "project module and entry settings must be strings"))
  (when (and (null? rpcs) (null? events) (null? states))
    (error 'generate-clients! "the backend declares no RPCs, Events, or shared states"))
  (validate-native-identifiers! rpcs events states)
  (write-generated!
   (project-path project "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")
   (generate-swift rpcs events states module-name entry-name))
  (write-generated!
   (project-path project "windows" "GeneratedBackend.hpp")
   (generate-cpp rpcs events states module-name entry-name))
  ;; Preserve the historical first two result positions for callers that
  ;; inspect codegen output programmatically; Events are appended in v0.2.
  (list rpcs states events))
