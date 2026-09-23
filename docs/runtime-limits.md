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

A request occupies one pending slot after it has been admitted and before its terminal Response/Error has been accepted by the output queue. The limit applies to both application RPCs and Rivet's reserved State requests because they share the same request lifecycle. When the limit is reached, Rivet returns a normal request-scoped Error frame for the new request instead of creating another request custodian and Racket thread; the existing requests continue running.

A request ID has a single owner while its entry remains pending. If another Request arrives with the same ID before that entry is released, the first request wins and the duplicate frame is ignored before its payload is parsed. The same ownership protection applies to syntactically valid RVT1 frame types that are illegal in the native-to-backend direction: if such a frame reuses a pending request ID, Rivet ignores it rather than emitting another Error with the same ID. Rivet must not send a second terminal frame for either collision because native clients correlate terminal frames only by ID; a competing Error could otherwise consume the original request's continuation. Illegal inbound frames whose ID is not pending retain the normal request-local Error diagnostic. Once the original terminal frame has been accepted by the output queue and the pending entry is released, the ID may be reused by a later request.

Cancellation, normal completion, and request failure compete for terminal ownership of the pending entry. Exactly one side can claim that ownership. A claimed request stays in the pending table until its terminal frame is admitted to the output queue; only then is its slot released. This matters when native output is stalled: completed requests cannot free their slots early and allow an unbounded number of additional workers to accumulate behind output backpressure.

State commit is the one short cancellation barrier. Before a setter owns its per-State update-order lock, Cancel remains immediate because no State side effect has happened. Once the State cell is committed, cancellation is deferred until the corresponding reserved `$state` Event has been accepted by the bounded output queue. A Cancel received during that interval marks the pending request but neither kills its worker nor releases its pending slot. After Event admission, the deferred cancellation atomically takes terminal ownership, emits the normal `request cancelled` Error, and stops the request custodian instead of allowing a normal Response. This keeps backend and native State views consistent without creating unbounded detached work behind output backpressure.

The pending table is synchronized because request workers complete concurrently with the server reader loop. Shutdown snapshots and clears the table under the same lock before stopping the remaining request custodians.

## Output backpressure

`serve` and `serve-fds` also accept `#:max-outgoing-frames`. The default output queue holds at most 64 frames waiting for the single writer thread.

```racket
(serve in out #:max-outgoing-frames 32)
```

The queue is intentionally bounded. If the native peer stops reading, RPC workers and Event producers block instead of appending frames to an unbounded in-memory queue. The reader itself is backpressured when it needs to emit a rejection or protocol Error, which prevents it from continuing to admit work faster than the transport can drain it.

The writer and application runtime are supervised separately. Producers wait for either output capacity or writer termination. If the output port fails, blocked producers are released, the internal reader/request runtime is shut down, and `serve` propagates the writer error rather than remaining blocked in `read-frame`. On orderly shutdown Rivet stops all producers first, drains every frame that was already accepted by the output queue, then stops the writer.

State updates use separate data and update-order locks. The State cell is committed under the short data lock and that lock is released before a reserved `$state` Event waits for output capacity. Pure Racket `state-ref` calls can therefore observe the committed value even while the native transport is backpressured. A private per-State update-order lock remains held until the Event is accepted, so subsequent setters cannot overtake the stalled update and `$state` Event order remains consistent with commit order. The cancellation barrier described above covers the same commit-to-Event interval, so cancellation cannot leave a committed State value without its native notification.

The queue limit is a frame-count bound, not a replacement for the RVT1 per-frame 64 MiB limit or the pending-request limit. These limits work together: value/frame limits bound each item, the outgoing queue bounds buffered frames, and the pending table bounds admitted request workers, including requests whose terminal frames are waiting for output capacity.

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

Malformed application-level requests, including unknown RPC names and invalid argument shapes, are returned as request-local Error frames. Application RPC results that cannot be serialized within RVT1 resource limits are also converted to request-local Error frames: a request remains claimable until response encoding succeeds, so a serialization failure cannot silently consume terminal-response ownership and leave the native client waiting indefinitely.

Application RPC workers also isolate every value that Racket can raise, not only the `exn:fail?` hierarchy. Standard exception values preserve their bounded `exn-message`. If application code raises a non-exception value, Rivet returns a fixed diagnostic instead of printing or echoing the arbitrary object. In both cases the request still claims and emits one terminal Error, then releases its pending slot; an unusual `raise` therefore cannot kill a worker while leaving the native client and concurrency limit permanently stuck.

Backend-generated Error diagnostics are capped at 4096 Unicode characters and longer messages end with `[truncated]`. Admitted requests prepare this bounded Error payload before they compete with cancellation for terminal ownership. Rejections that happen before admission use the same bounded encoder, so an oversized unknown RPC name or exception message cannot escape the reader loop merely while Rivet is trying to report the failure.

Diagnostic construction is bounded before that final truncation step as well. Type mismatches report only the argument/result position, declared type, and a small safe value-kind label instead of printing the actual application object. Structurally invalid decoded RPC payloads use a fixed diagnostic rather than rendering the entire decoded tree, and non-exception values passed to the inherited `exit` handler are not formatted. Custom writers or very large values therefore cannot perform unbounded work merely because Rivet is constructing an Error message.

A failed State serialization preflight is request-local as well: the State cell is not changed and no `$state` Event is queued. This gives State updates a wire-atomic boundary rather than mutating backend state first and discovering later that native clients cannot observe the new value.

Framing failures are different: invalid RVT1 magic/version, truncated transport data, output-port failure, or other transport-level corruption can terminate the connection because reliable frame delivery can no longer be guaranteed.