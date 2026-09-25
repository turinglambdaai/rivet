# Changelog

## 0.2.0

Rivet 0.2 hardens the native runtime contract and release path while preserving the existing WinUI 3 / SwiftUI architecture.

- Deterministic embedded Racket lifecycle on macOS, including idempotent stop and restart rejection.
- Standalone Swift `RivetClient` instances now use the same one-shot lifecycle: start is reserved before the Hello read, concurrent starts are rejected, and stop/startup races cannot resurrect a stopped client.
- Typed Event schema validation and generated Swift/C++ Event APIs.
- Native identifier collision detection and language-specific codegen string escaping.
- Bounded RVT1 frame/value byte size, value nesting, total value-node count, concurrent backend requests, declared/incoming API-name size, and queued backend output.
- Racket List encoding applies the value-node budget while discovering list length instead of fully traversing oversized Lists before rejecting them; improper Lists fail explicitly without formatting the entire value.
- Racket protocol encoding reports unsupported application values without formatting the object itself, so custom writers cannot amplify or replace the original codec failure.
- Synchronized request cancellation/completion ownership and non-zero UInt64 Event ID allocation; Event IDs wrap from `2^64-1` back to `1`, while terminal requests keep their pending slot until their Response/Error is admitted to the bounded output queue.
- Duplicate Request IDs and illegal inbound frame types that collide with a pending request use first-request-wins semantics, preventing a second terminal frame from consuming the original native caller's continuation; IDs become reusable after release.
- Native Windows/macOS request-ID allocators skip zero and still-pending IDs across UInt64 wraparound; cancellation is latched until its Request frame is written so Cancel cannot overtake Request on the wire.
- Native Cancel writes are linearized with pending-request ownership, so a response cannot release an ID between the final ownership check and the Cancel write and let a stale cancellation cross into a later wrapped request that reuses the same ID.
- State commits defer request cancellation only across the commit-to-`$state`-Event admission window, keeping the pending slot occupied so a committed State cannot lose its native notification under output backpressure.
- Backend reader/writer supervision propagates output-port failure and stops producers instead of leaving the server blocked behind a dead writer.
- State data locking is separated from per-State update/Event ordering, so output backpressure cannot block pure Racket `state-ref` calls while concurrent setters still preserve `$state` Event order.
- Request-local handling for malformed application RPC requests and response-serialization failures, with bounded backend Error diagnostics that cannot consume terminal-response ownership before encoding succeeds.
- Diagnostic construction avoids formatting arbitrary application values or entire malformed decoded trees before final Error truncation, preventing custom writers or large values from amplifying failure reporting work.
- Request workers convert every Racket raised value, including base exceptions and non-exception values, into bounded request-local Errors so unusual application raises cannot leak pending slots or strand native callers.
- State initial values and updates are preflighted as complete `$state` Events, so serialization failures cannot partially commit backend state without notifying native clients.
- Application version, build, display-name, identifier, and Windows/macOS minimum-version metadata are centralized in `rivet.rktd` with backwards-compatible defaults.
- Shared RVT1 golden vectors consumed by Racket, C++, and Swift tests.
- Deterministic 512-value RVT1 property corpora in Racket, C++, and Swift replay the same PRNG sequence, verify canonical round-trips/truncation rejection, and assert a shared encoded-byte fingerprint.
- An opt-in Clang/libFuzzer harness exercises native RVT1 value/frame decoding under ASan and UBSan; pull requests run a bounded fuzz smoke campaign seeded from the shared golden vectors.
- Strict UTF-8 validation and unknown message-type rejection across protocol implementations.
- Racket validates frame IDs as unsigned 64-bit values before writing any bytes, matching native UInt64 semantics and preventing local argument errors from leaving partial frames on the transport.
- Generated Windows RPC/State completion APIs provide non-blocking, cancellable WinUI-friendly calls while preserving the existing `std::future` API.
- `raco rivet package` now verifies the produced dependency closure, and `raco rivet verify` can re-audit an existing Windows/macOS artifact.
- Explicit `--production` packaging supports Windows Authenticode + RFC 3161 timestamping and macOS Developer ID signing + notarization/stapling without storing publisher credentials in project files.
- `raco rivet doctor` reports the exact selected Racket/native artifacts, `doctor --json` exposes the same diagnostics to CI/Agents, and `raco rivet clean` safely removes only generated project artifacts.
- Racket runtime discovery uses bounded installation-layout probes instead of recursive prefix scans, keeping `doctor` and builds fast even when Racket is installed under a large system prefix such as `/usr`.
- Windows toolchain discovery resolves a Visual Studio installation once and derives a complete MSVC toolset from bounded directories instead of spawning `vswhere.exe` separately for every compiler utility.
- Tag-driven release workflow with version/changelog validation and packaged Racket artifacts.

## 0.1.0

Initial Rivet runtime milestone.

- RVT1 protocol implemented in Racket, C++, and Swift.
- Embedded Racket CS hosts for WinUI 3 and SwiftUI.
- Typed RPC and State schema validation with generated Swift/C++ clients.
- Shared State get/set operations and `$state` change events.
- Request, response, error, event, cancellation, and shutdown lifecycle.
- `raco rivet new`, `doctor`, `build`, `dev`, and `package`.
- Generated WinUI and SwiftUI starters exercise shared State end to end.
- Exact Racket runtime discovery; no adjacent-version fallback.
- Self-contained Windows package output and hardened-runtime macOS app bundles.
- Cross-platform protocol tests and native host CI smoke builds.
