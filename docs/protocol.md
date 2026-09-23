# RVT1 Protocol

RVT1 is Rivet's platform-neutral framing and value protocol. It is intentionally small enough to implement consistently in Racket, C++, and Swift.

All multi-byte integers are little-endian.

## Frame

```text
Offset  Size  Field
0       4     ASCII magic "RVT1"
4       1     protocol version (1)
5       1     message type
6       8     request/event id, unsigned 64-bit
14      4     payload length, unsigned 32-bit
18      N     payload bytes
```

A transport must preserve byte order but does not need to preserve write boundaries. Readers therefore use exact-length reads. RVT1 v1 limits a frame payload to 64 MiB before allocation or decoding.

## Message types

| Value | Name | Direction | Meaning |
|---:|---|---|---|
| 1 | Hello | backend → native | handshake after the Racket server is ready |
| 2 | Request | native → backend | RPC or built-in State request |
| 3 | Response | backend → native | successful request result |
| 4 | Error | either | request or protocol failure |
| 5 | Event | backend → native | asynchronous backend event |
| 6 | Cancel | native → backend | cancel request with matching id |
| 7 | Shutdown | native → backend | orderly backend shutdown |

Unknown message types must not be interpreted as another known type. A peer may report them as protocol errors.

## Value codec

Payloads use tagged values.

| Tag | Type | Encoding |
|---:|---|---|
| `0x00` | Null / Void | no payload |
| `0x01` | Bool false | no payload |
| `0x02` | Bool true | no payload |
| `0x03` | Int64 | 8-byte signed two's-complement integer |
| `0x04` | String | u32 byte length + UTF-8 bytes |
| `0x05` | Bytes | u32 byte length + raw bytes |
| `0x06` | List | u32 element count + recursively encoded elements |

A decoder rejects trailing bytes after the top-level value. Strings are UTF-8; invalid UTF-8 is a decoding error.

A standalone encoded value is also bounded to 64 MiB because it must fit in a legal frame payload. Racket, C++, and Swift encoders enforce that limit while constructing the value instead of first building an oversized payload and failing only at frame write. Standalone value decoders reject inputs larger than 64 MiB before parsing. Length-prefixed `String` and `Bytes` decoders validate the declared u32 length against the bytes actually remaining before copying the field.

Racket, C++, and Swift enforce two additional value-shape resource limits: at most 64 nested `List` levels and at most 262,144 total value nodes per top-level value, including the root. Before allocating a `List`, a decoder verifies that its declared element count can fit in the remaining node budget. Encoders enforce the same node budget. These are codec resource bounds rather than schema restrictions: ordinary application values are unaffected, while adversarial or accidentally huge nested/container payloads cannot drive unbounded recursive parsing or object allocation. Large opaque payloads should use `Bytes` rather than enormous `List` values.

## Hello

The server sends Hello before accepting application-level responses.

Payload:

```text
["rivet", 1]
```

where `1` is the protocol version encoded as Int64.

The native host should not report the backend as ready until it validates this frame.

## Request

Request `id` is allocated by the native client and must be unique among outstanding requests.

Application RPC payload:

```text
["rpc-name", arg0, arg1, ...]
```

Example:

```text
frame.type = Request
frame.id   = 42
payload    = ["increment", 41]
```

State uses the same Request/Response framing through reserved built-in request names:

```text
["$state/get", "counter"]
["$state/set", "counter", 42]
```

No additional frame type is required for State, so RPC and State share the same request IDs, error handling, cancellation boundary, and transport implementation.

## Response

A successful response carries the same request id and one encoded result value.

```text
frame.type = Response
frame.id   = 42
payload    = 42
```

Void procedures return the Null/Void value. `$state/get` and `$state/set` return the current State value.

## Error

Errors associated with requests reuse the request id. The v1 error payload is a UTF-8 String containing a human-readable message.

Structured error codes and stack metadata can be added as a higher-level value shape without changing the frame format.

## Cancel

Cancel uses the id of the request to cancel. Its payload is currently empty and ignored.

The Racket server associates each request with a custodian. Cancellation shuts down that custodian. A cancelled request receives an Error response when possible.

## Shutdown

Shutdown uses id 0 and an empty payload. After shutdown, the backend closes its protocol ports and the native host waits for its runtime/reader workers before teardown completes. An embedded backend instance is process-scoped and is not restartable after shutdown in the current runtime contract.

## Events

The Racket backend can declare an event with `define-event` or emit one directly with `emit-event!`.

Event payload:

```text
["event-name", value]
```

Event IDs use their own monotonically increasing namespace and are not request IDs. Native clients deliver decoded events through their event callback. Event callbacks run on a transport/reader thread; UI code must dispatch to the WinUI dispatcher or Swift MainActor before touching native UI objects.

Events may be typed:

```racket
(define-event progress : Int64)
```

The payload is validated at the Racket boundary before it is emitted. The legacy form remains supported:

```racket
(define-event progress)
```

and is equivalent to an `Any` payload for compatibility with pre-0.2 applications.

Typed Event declarations are included in code generation. Swift receives a `RivetEvent` enum with typed associated values and a decoder from the generic transport callback. C++ receives typed Event structs, an `Event` `std::variant`, and a decoder. The wire representation remains the same RVT1 Event payload; typed Events are a schema/codegen layer rather than a framing change.

A successful State update emits the reserved `$state` event. Its value is `[state-name, value]`, so the complete Event payload is:

```text
["$state", ["counter", 42]]
```

`$state` is a reserved runtime event rather than an application `define-event` declaration. Native code can subscribe once and react to State changes without polling.

## Typed RPC, Event, and State schema

`define-rpc` records argument names, argument types, and the result type. `define-event` records the Event name and payload type. `define-state` records the State name, value type, and current value. Rivet validates values at the Racket boundary and generates Swift/C++ wrappers before each native build.

Schema types are `String`, `Int64`, `Bool`, `Bytes`, `Void`, `Any`, `(List T)`, and `(Optional T)`. State and Event payloads accept the same value types except `Void`. Optional null is encoded with the existing Null/Void tag, so typed schema evolution does not change RVT1 framing.

Generated State accessors use `$state/get` and `$state/set` internally; applications normally call the typed Swift/C++ API rather than constructing those reserved requests directly.

Code generation rejects declarations that normalize to the same Swift or C++ identifier. Rivet reports the conflicting source declarations instead of writing native source that later fails with an opaque compiler error.

## Compatibility

Rivet will keep framing changes explicit. If a future release cannot decode the v1 frame/value format, it must increment the protocol version and fail the Hello negotiation instead of guessing.

Resource limits such as maximum frame/value byte size, value nesting, and total value-node count are part of the v1 decoder contract and are tested consistently across the Racket, C++, and Swift implementations.
