#lang racket/base

(require racket/list
         racket/match
         racket/string
         "model.rkt"
         "naming.rkt"
         "type-graph.rkt")

(provide generate-swift)

(define swift-schema-namespace "RivetTypes")

(define (swift-schema-type-name name)
  (format "~a.~a"
          swift-schema-namespace
          (record-native-name name swift-id)))

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
         (swift-schema-type-name type)
         (error 'generate-clients! "unsupported Swift type: ~e" type))]))

(define (swift-record-definition record)
  (define name (record-native-name (schema-record-name record) swift-id))
  (define fields (map swift-id (schema-record-field-names record)))
  (define types (schema-record-field-types record))
  (define declarations
    (apply string-append
           (for/list ([field (in-list fields)] [type (in-list types)])
             (format "        public let ~a: ~a\n" field (swift-type type)))))
  (define params
    (string-join
     (for/list ([field (in-list fields)] [type (in-list types)])
       (format "~a: ~a" field (swift-type type)))
     ", "))
  (define assignments
    (apply string-append
           (for/list ([field (in-list fields)])
             (format "            self.~a = ~a\n" field field))))
  (define conformances
    (if (memq (schema-record-name record) (current-swift-codable-types))
        "Codable, Sendable"
        "Sendable"))
  (format "    public struct ~a: ~a {\n~a        public init(~a) {\n~a        }\n    }\n\n"
          name conformances declarations params assignments))

(define (swift-enum-definition enum)
  (define name (record-native-name (schema-enum-name enum) swift-id))
  (define conformances
    (if (memq (schema-enum-name enum) (current-swift-codable-types))
        "String, Codable, Sendable"
        "String, Sendable"))
  (string-append
   (format "    public enum ~a: ~a {\n" name conformances)
   (apply string-append
          (for/list ([case (in-list (schema-enum-cases enum))])
            (format "        case ~a = ~a\n"
                    (swift-id case)
                    (swift-string-literal (symbol->string case)))))
   "    }\n\n"))

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
  ;; Match the RPC surface: Swift identifiers stay snake_case end to end, so
  ;; accessors are get_<state>/set_<state> rather than a camelCase get prefix
  ;; glued onto a snake body (getRepo_root).
  (define name (swift-id raw-name))
  (define type (schema-state-type state))
  (format
   "    public func get_~a() async throws -> ~a {\n        let result = try await client.getState(~a)\n        return try decode_~a(result)\n    }\n    @discardableResult\n    public func set_~a(_ value: ~a) async throws -> ~a {\n        let result = try await client.setState(~a, value: encode_~a(value))\n        return try decode_~a(result)\n    }\n"
   name (swift-type type) (swift-string-literal raw-name) (type-key type)
   name (swift-type type) (swift-type type) (swift-string-literal raw-name) (type-key type) (type-key type)))

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

(define (swift-device-response-type type)
  (if (eq? type 'Void) "RivetDeviceUnit" (swift-type type)))

(define (swift-device-request-definition rpc)
  (define request-name (swift-device-request-name rpc))
  (define names (map swift-id (schema-rpc-arg-names rpc)))
  (define types (schema-rpc-arg-types rpc))
  (define declarations
    (apply string-append
           (for/list ([name (in-list names)] [type (in-list types)])
             (format "        public let ~a: ~a\n" name (swift-type type)))))
  (define params
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "~a: ~a" name (swift-type type)))
     ", "))
  (define assignments
    (apply string-append
           (for/list ([name (in-list names)])
             (format "            self.~a = ~a\n" name name))))
  (string-append
   (format "    public struct ~a: RivetDeviceRequest {\n" request-name)
   (format "        public typealias Response = ~a\n"
           (swift-device-response-type (schema-rpc-result-type rpc)))
   (format "        public static let route = ~a\n"
           (swift-string-literal
            (string-append "rpc." (symbol->string (schema-rpc-name rpc)))))
   declarations
   (format "        public init(~a) {\n" params)
   assignments
   "        }\n"
   "    }\n"))

(define (swift-device-client-method rpc)
  (define names (map swift-id (schema-rpc-arg-names rpc)))
  (define types (schema-rpc-arg-types rpc))
  (define result (schema-rpc-result-type rpc))
  (define params
    (string-join
     (for/list ([name (in-list names)] [type (in-list types)])
       (format "~a: ~a" name (swift-type type)))
     ", "))
  (define arguments
    (string-join
     (for/list ([name (in-list names)]) (format "~a: ~a" name name))
     ", "))
  (if (eq? result 'Void)
      (format "    func ~a(~a) async throws {\n        _ = try await send(RivetDeviceRequests.~a(~a))\n    }\n"
              (swift-id (schema-rpc-name rpc)) params
              (swift-device-request-name rpc) arguments)
      (format "    func ~a(~a) async throws -> ~a {\n        try await send(RivetDeviceRequests.~a(~a))\n    }\n"
              (swift-id (schema-rpc-name rpc)) params (swift-type result)
              (swift-device-request-name rpc) arguments)))

(define (swift-device-router-registration rpc)
  (define names (map swift-id (schema-rpc-arg-names rpc)))
  (define result (schema-rpc-result-type rpc))
  (define arguments
    (string-join
     (for/list ([name (in-list names)]) (format "~a: request.~a" name name))
     ", "))
  (define call
    (format "try await api.~a(~a)" (swift-id (schema-rpc-name rpc)) arguments))
  (if (eq? result 'Void)
      (format "        try register(RivetDeviceRequests.~a.self) { request in\n            ~a\n            return RivetDeviceUnit()\n        }\n"
              (swift-device-request-name rpc) call)
      (format "        try register(RivetDeviceRequests.~a.self) { request in\n            ~a\n        }\n"
              (swift-device-request-name rpc) call)))

(define (generate-swift-device-api rpcs)
  (if (null? rpcs)
      ""
      (string-append
       (if (ormap (lambda (rpc) (eq? (schema-rpc-result-type rpc) 'Void)) rpcs)
           "public struct RivetDeviceUnit: Codable, Sendable { public init() {} }\n\n"
           "")
       "public enum RivetDeviceRequests {\n"
       (apply string-append (map swift-device-request-definition rpcs))
       "}\n\n"
       "public extension RivetDeviceClient {\n"
       (apply string-append (map swift-device-client-method rpcs))
       "}\n\n"
       "public extension RivetDeviceRouter {\n"
       "    func registerGeneratedBackend(_ api: RivetAPI) throws {\n"
       (apply string-append (map swift-device-router-registration rpcs))
       "    }\n"
       "}\n")))

(define (generate-swift rpcs events states records enums device-rpcs
                        module-name entry-name display-name version build
                        identifier release-channel)
  (define types (all-types rpcs events states records enums))
  (string-append
   "// Generated by Rivet. Do not edit by hand.\nimport Foundation\nimport RivetRuntime\n"
   (if (null? device-rpcs) "\n" "import RivetDevice\n\n")
   "public enum RivetGeneratedError: Error { case typeMismatch(String); case unknownEvent(String) }\n"
   (format "public enum RivetGeneratedConfig {\n    public static let moduleName = ~a\n    public static let entryName = ~a\n    public static let displayName = ~a\n    public static let version = ~a\n    public static let build: Int64 = ~a\n    public static let identifier = ~a\n    public static let releaseChannel = ~a\n}\n\n"
           (swift-string-literal module-name)
           (swift-string-literal entry-name)
           (swift-string-literal display-name)
           (swift-string-literal version)
           build
           (swift-string-literal identifier)
           (swift-string-literal release-channel))
   (if (and (null? records) (null? enums))
       ""
       (string-append
        "public enum RivetTypes {\n"
        (apply string-append (map swift-enum-definition enums))
        (apply string-append (map swift-record-definition (order-records records)))
        "}\n\n"))
   (apply string-append (map swift-encoder types))
   "\n"
   (apply string-append (map swift-decoder types))
   "\n"
   (generate-swift-events events)
   "public struct RivetAPI: Sendable {\n    public let client: RivetClient\n    public init(client: RivetClient) { self.client = client }\n\n"
   (apply string-append (map swift-rpc-method rpcs))
   (if (null? states) "" "\n    // Shared state\n")
   (apply string-append (map swift-state-methods states))
   "}\n"
   (if (null? device-rpcs)
       ""
       (string-append "\n" (generate-swift-device-api device-rpcs)))))
