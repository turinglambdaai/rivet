# Runtime limits

Rivet runs trusted application code in-process, but the runtime still applies bounded protocol and request limits so an application bug cannot grow work queues without bound.

## Pending requests

`serve` and `serve-fds` accept an optional `#:max-pending-requests` keyword. The default is 1024 concurrent requests.

```racket
(serve in out #:max-pending-requests 256)
```

or, for an embedded native host:

```racket
(serve-fds in-fd out-fd #:max-pending-requests 256)
```

A request occupies one pending slot after it has been admitted and before it returns, fails, or is cancelled. The limit applies to both application RPCs and Rivet's reserved State requests because they share the same request lifecycle. When the limit is reached, Rivet returns a normal request-scoped Error frame for the new request instead of creating another request custodian and Racket thread; the existing requests continue running.

Cancellation and normal completion compete for ownership of the pending entry. Exactly one side removes that entry and emits the terminal response/error for the request. Cancelling a request therefore releases its slot before another request is admitted.

The pending table is synchronized because request workers complete concurrently with the server reader loop. Shutdown snapshots and clears the table under the same lock before stopping the remaining request custodians.

## Events

Event identifiers are allocated under a lock because multiple RPC workers can emit Events concurrently. Event delivery still uses the single response writer, so RVT1 frames cannot interleave on the output stream.

Event handlers execute on native runtime/reader threads. Application UI code must dispatch to the WinUI dispatcher or Swift MainActor before mutating UI state.

## Wire values

RVT1 v1 applies the same resource limits in Racket, C++, and Swift:

- a single frame payload is at most 64 MiB;
- a standalone encoded value is at most 64 MiB, so it is always eligible to be used as one frame payload;
- a recursively encoded value is at most 64 nested `List` levels;
- one encoded/decoded value contains at most 262,144 total value nodes, including the root value and every nested `List` element.

Value encoders enforce the byte budget while constructing output instead of first allocating an oversized encoded payload and failing later at frame write. Standalone decoders reject inputs larger than 64 MiB before parsing. Length-prefixed `String` and `Bytes` fields validate their declared length against the actual remaining input before copying, so a tiny forged payload cannot request a multi-gigabyte field read.

The node budget prevents a small or merely frame-sized wire payload from expanding into an unbounded number of language-level `Value`/list objects. Decoders validate a declared `List` count against the remaining node budget before reserving or constructing the destination container. Encoders apply the same budget, so an accidental application-side giant `List` is rejected before recursively encoding its elements. Large binary payloads should use `Bytes`, which counts as one value node regardless of byte length and remains governed by the 64 MiB value/frame-size limit.

State values are additionally preflighted as their complete reserved `$state` Event before storage. Initial values that cannot be synchronized are rejected by `define-state`. Updates encode the Event before changing the State cell and reuse that payload on success, so a type-correct value that exceeds RVT1 limits cannot leave Racket and native state views inconsistent.

Declared RPC, Event, and State API names are limited to 1024 UTF-8 bytes. Incoming RPC and State lookup names use the same byte limit and are rejected before `string->symbol`, preventing arbitrary wire input from creating oversized registry-lookup symbols. Error messages report only the measured length and configured maximum rather than echoing an oversized name.

These are defensive resource limits, not application schema limits. Normal `String`, `Bytes`, `List`, `Optional`, RPC, State, and Event usage is unchanged.

## Failure isolation

Malformed application-level requests, including unknown RPC names and invalid argument shapes, are returned as request-local Error frames. Application RPC results that cannot be serialized within RVT1 resource limits are also converted to request-local Error frames: a request remains pending until response encoding succeeds, so a serialization failure cannot silently consume terminal-response ownership and leave the native client waiting indefinitely.

Backend-generated Error diagnostics are capped at 4096 Unicode characters and longer messages end with `[truncated]`. Admitted requests prepare this bounded Error payload before they compete with cancellation for terminal ownership. Rejections that happen before admission use the same bounded encoder, so an oversized unknown RPC name or exception message cannot escape the reader loop merely while Rivet is trying to report the failure.

A failed State serialization preflight is request-local as well: the State cell is not changed and no `$state` Event is queued. This gives State updates a wire-atomic boundary rather than mutating backend state first and discovering later that native clients cannot observe the new value.

Framing failures are different: invalid RVT1 magic/version, truncated transport data, or other transport-level corruption can terminate the connection because frame boundaries can no longer be trusted.
