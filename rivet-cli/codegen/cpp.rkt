#lang racket/base

(require racket/list
         racket/match
         racket/string
         "model.rkt"
         "naming.rkt"
         "type-graph.rkt")

(provide generate-cpp)

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

(define (cpp-enum-definition enum)
  (define name (record-native-name (schema-enum-name enum) cpp-id))
  (format "enum class ~a { ~a };\n\n"
          name
          (string-join (map cpp-id (schema-enum-cases enum)) ", ")))

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

;; The call-result local and the async-handler lambda parameter use
;; reserved `rivet_` names: argument names come from the schema, and a
;; schema arg named `raw` used to collide with the emitted `auto raw`
;; (C2082) and retarget `.get()` at the parameter. The reserved names are
;; also added to cpp-keywords in naming.rkt, so a schema id spelled the
;; same gets the usual rivet_ prefix and can never collide either.
(define (cpp-future result-type raw-expression)
  (define result (cpp-type result-type))
  (define decode
    (if (eq? result-type 'Void)
        (format "detail::decode_~a(rivet_call.get());" (type-key result-type))
        (format "return detail::decode_~a(rivet_call.get());" (type-key result-type))))
  (format
   "auto rivet_call = ~a; return std::async(std::launch::deferred, [rivet_call = std::move(rivet_call)]() mutable -> ~a { ~a });"
   raw-expression result decode))

(define (cpp-async-handler result-type backend-namespace)
  (define result (cpp-type result-type))
  ;; Result<void> has no value member, so the Void decode must not assign
  ;; into it — it only validates that a value arrived.
  (define decode
    (if (eq? result-type 'Void)
        (format "detail::decode_~a(*rivet_result.value);" (type-key result-type))
        (format "result.value = detail::decode_~a(*rivet_result.value);" (type-key result-type))))
  (format
   "[completion = std::move(completion)](~a::CallResult rivet_result) mutable { Result<~a> result; if (rivet_result.error) { result.error = rivet_result.error; } else { try { if (!rivet_result.value) throw std::runtime_error(\"Rivet async call completed without a value\"); ~a } catch (...) { result.error = std::current_exception(); } } completion(std::move(result)); }"
   backend-namespace result decode))

;; Bounded-wait companion (issue #252): the completion side of request_async
;; resolves a promise, so a poller waits up to the timeout and cancels the
;; request if it is still pending. Void RPCs return bool (false = timed
;; out); other results return std::nullopt on timeout. Backend errors still
;; throw from the final get, keeping the blocking call's error contract.
(define (cpp-promise-handler result-type backend-namespace)
  (define settle
    (if (eq? result-type 'Void)
        (format "detail::decode_~a(*rivet_result.value);" (type-key result-type))
        (format "rivet_done->set_value(detail::decode_~a(*rivet_result.value));"
                (type-key result-type))))
  (format
   "[rivet_done](~a::CallResult rivet_result) mutable { if (rivet_result.error) { rivet_done->set_exception(rivet_result.error); } else { try { if (!rivet_result.value) throw std::runtime_error(\"Rivet async call completed without a value\"); ~a } catch (...) { rivet_done->set_exception(std::current_exception()); } } }"
   backend-namespace settle))

(define (cpp-within-method info backend-namespace)
  (define names (map cpp-id (schema-rpc-arg-names info)))
  (define types (schema-rpc-arg-types info))
  (define result-type (schema-rpc-result-type info))
  (define void? (eq? result-type 'Void))
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
  (define return-type
    (if void? "bool" (format "std::optional<~a>" (cpp-type result-type))))
  (define timed-out-return (if void? "false" "std::nullopt"))
  (define final-get
    (if void?
        "rivet_done->get_future().get(); return true;"
        "return rivet_done->get_future().get();"))
  (format
   "  ~a ~a_within(~a, std::chrono::milliseconds rivet_timeout) { auto rivet_done = std::make_shared<std::promise<~a>>(); auto rivet_id = backend_.request_async(~a, rivet::Value::List{~a}, ~a); if (rivet_done->get_future().wait_for(rivet_timeout) != std::future_status::ready) { backend_.cancel(rivet_id); return ~a; } ~a }\n"
   return-type
   (cpp-id (schema-rpc-name info))
   params
   (cpp-type result-type)
   rpc-name encoded
   (cpp-promise-handler result-type backend-namespace)
   timed-out-return final-get))

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
   "  std::future<~a> ~a(~a) { ~a }\n  [[nodiscard]] std::uint64_t ~a_async(~a) { if (!completion) throw std::invalid_argument(\"Rivet async completion handler is empty\"); return backend_.request_async(~a, rivet::Value::List{~a}, ~a); }\n~a"
   (cpp-type result-type)
   (cpp-id (schema-rpc-name info))
   params
   (cpp-future result-type
               (format "backend_.call(~a, rivet::Value::List{~a})"
                       rpc-name encoded))
   (cpp-id (schema-rpc-name info))
   async-params
   rpc-name encoded (cpp-async-handler result-type backend-namespace)
   (cpp-within-method info backend-namespace)))

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

(define (generate-cpp rpcs events states records enums
                      module-name entry-name display-name version build
                      identifier release-channel backend-namespace)
  (define types (all-types rpcs events states records enums))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n#pragma once\n\n#include <chrono>\n#include <cstdint>\n#include <exception>\n#include <functional>\n#include <future>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <variant>\n#include <vector>\n\n#include \"backend.hpp\"\n\nnamespace rivet_app {\n"
   (format "inline constexpr char kModuleName[] = ~a;\ninline constexpr char kEntryName[] = ~a;\ninline constexpr char kDisplayName[] = ~a;\ninline constexpr char kVersion[] = ~a;\ninline constexpr std::int64_t kBuild = ~a;\ninline constexpr char kIdentifier[] = ~a;\ninline constexpr char kReleaseChannel[] = ~a;\n\n"
           (cpp-string-literal module-name)
           (cpp-string-literal entry-name)
           (cpp-string-literal display-name)
           (cpp-string-literal version)
           build
           (cpp-string-literal identifier)
           (cpp-string-literal release-channel))
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
