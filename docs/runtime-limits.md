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
- a recursively encoded value is at most 64 nested `List` levels;
- one encoded/decoded value contains at most 262,144 total value nodes, including the root value and every nested `List` element.

The node budget prevents a small or merely frame-sized wire payload from expanding into an unbounded number of language-level `Value`/list objects. Decoders validate a declared `List` count against the remaining node budget before reserving or constructing the destination container. Encoders apply the same budget, so an accidental application-side giant `List` is rejected before recursively encoding its elements. Large binary payloads should use `Bytes`, which counts as one value node regardless of byte length and remains governed by the frame-size limit.

These are defensive resource limits, not application schema limits. Normal `String`, `Bytes`, `List`, `Optional`, RPC, State, and Event usage is unchanged.

## Failure isolation

Malformed application-level requests, including unknown RPC names and invalid argument shapes, are returned as request-local Error frames. They do not intentionally terminate the embedded Racket server.

Framing failures are different: invalid RVT1 magic/version, truncated transport data, or other transport-level corruption can terminate the connection because frame boundaries can no longer be trusted.
