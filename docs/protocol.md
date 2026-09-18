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

A transport must preserve byte order but does not need to preserve write boundaries. Readers therefore use exact-length reads.

## Message types

| Value | Name | Direction | Meaning |
|---:|---|---|---|
| 1 | Hello | backend → native | handshake after the Racket server is ready |
| 2 | Request | native → backend | RPC invocation |
| 3 | Response | backend → native | successful RPC result |
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

Payload:

```text
["rpc-name", arg0, arg1, ...]
```

Example:

```text
frame.type = Request
frame.id   = 42
payload    = ["increment", 41]
```

## Response

A successful response carries the same request id and one encoded result value.

```text
frame.type = Response
frame.id   = 42
payload    = 42
```

Void procedures return the Null/Void value.

## Error

Errors associated with requests reuse the request id. The v1 error payload is a UTF-8 String containing a human-readable message.

Structured error codes and stack metadata can be added as a higher-level value shape without changing the frame format.

## Cancel

Cancel uses the id of the request to cancel. Its payload is currently empty and ignored.

The Racket server associates each request with a custodian. Cancellation shuts down that custodian. A cancelled request receives an Error response when possible.

## Shutdown

Shutdown uses id 0 and an empty payload. After shutdown, the backend closes its protocol ports and the native client joins its runtime threads.

## Events

The Racket backend can declare an event with `define-event` or emit one directly with `emit-event!`.

Event payload:

```text
["event-name", value]
```

Event IDs use their own monotonically increasing namespace and are not request IDs. Native clients deliver decoded events through their event callback. Event callbacks run on a transport/reader thread; UI code must dispatch to the WinUI dispatcher or Swift MainActor before touching native UI objects.

## Typed RPC schema

`define-rpc` records argument names, argument types, and the result type. Rivet validates values at the Racket boundary and generates Swift/C++ wrappers before each native build.

Schema types are `String`, `Int64`, `Bool`, `Bytes`, `Void`, `Any`, `(List T)`, and `(Optional T)`. Optional null is encoded with the existing Null/Void tag, so typed schema evolution does not change RVT1 framing.

## Compatibility

Rivet will keep framing changes explicit. If a future release cannot decode the v1 frame/value format, it must increment the protocol version and fail the Hello negotiation instead of guessing.
