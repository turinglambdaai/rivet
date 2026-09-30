# Changelog

## Unreleased

- Add an agent-readable capability-sourcing contract. Generated projects now teach humans and coding agents how to choose among Racket packages, first-party native host APIs, safe FFI wrappers, argv-based CLI integrations, isolated sidecars, and owned implementations; `inspect --json` exposes the same decision order and release/security checklist as structured data.
- Complete the Linux release path. `raco rivet release` now runs on Linux: the verified self-contained package is packed into a deterministic ustar/gzip archive and signed with a detached Ed25519 signature (`<installer>.tar.gz.sig`, base64), configured through `RIVET_LINUX_SIGN_PRIVATE_KEY` and `RIVET_LINUX_SIGN_KEY_ID`. `raco rivet verify --production` re-derives the archive from the packaged directory, requires a byte-identical match with the released installer, and validates the signature against `RIVET_LINUX_SIGN_PUBLIC_KEY`; update manifests record the artifact as platform `linux`, installer kind `targz`. `raco rivet package --production` on Linux now points to `raco rivet release`, which owns the installer-level signing flow.

## 0.4.0

- Require Racket 9.0+ with the CS runtime (`base #:version "9.0"`); the legacy BC engine and pre-9.0 releases are no longer supported. State the floor in the landing page and getting-started guides.
- Add an agent-native project contract: generated `AGENTS.md` guidance plus `raco rivet inspect --json` for versioned project identity, native edit points, target maturity, generated-path ownership, and safe command discovery.
- Add validated application resource declarations, stable Racket-side resource lookup, Windows `.ico` compilation, and macOS `.icns` bundle metadata. Resources now participate in build, package, and verification instead of relying on platform-specific copy scripts.
- Promote Linux from a manually built GTK4 experiment to a developer preview: new projects include the Linux host, code generation emits a `rivet::linux_runtime` client, and `doctor`, `build`, `dev`, `package`, and `verify` support a statically embedded Racket CS runtime with real end-to-end CI.
- Make the portable Swift runtime available to iOS/iPadOS 16 and watchOS 9, and add a bounded, versioned `RivetDevice` request/response layer with a WatchConnectivity adapter for type-safe phone/watch companion communication.
- Add a Kotlin RVT1 codec foundation for Android, pinned Gradle tooling, and CI coverage against the same protocol vectors used by Racket, C++, and Swift.
- Add an Android coroutine client with bounded concurrent calls, Events, State helpers, backend errors, cancellation ordering, lifecycle enforcement, and deterministic Shutdown/stream cleanup.

## 0.3.0

- Added installable, searchable Scribble documentation for the core backend, system services, secure distribution APIs, and CLI workflow.
- Registered the normal installation path as `raco pkg install --auto rivet` and corrected the package license metadata to the SPDX `MIT` license identifier.
- Added an RVT1-independent `rivet/distribution` layer with SemVer channel policy, signed update manifests, Ed25519 verification, bounded downloads, SHA-256 artifact verification, staged rollout, install/restart callbacks, and rollback policy.
- Added `raco rivet release` to compose production packaging, WiX MSI or notarized DMG creation, update metadata, CycloneDX SBOM, third-party notices, and license audit output.
- Added `rivet/system` APIs for single-instance activation, notification/tray services, autostart, secure storage, atomic settings, structured logging, and provider-neutral crash hooks.
- Added first-party Windows implementations using Win32, Credential Manager, registry login startup, and Shell notifications, plus macOS implementations using AppKit, Keychain, UserNotifications, and ServiceManagement.
- Added project-level release channels, URL schemes, and file associations; macOS packaging emits the corresponding bundle metadata.
- Prepared Windows native builds and package naming for ARM64 while preserving the existing x64 path.
- Added manifest signature/tampering, version/channel, rollout, artifact-integrity, rollback, settings, logging, and system-adapter tests.
- Added an experimental GTK4/Linux embedded-host slice with real Racket CS round-trip coverage; CLI code generation, packaging, and compositor policy remain follow-up work.

## 0.2.0

Rivet 0.2 hardens the native runtime contract and release path while preserving the existing WinUI 3 / SwiftUI architecture, and completes the first-run developer experience for the first public release.

- First-run installation no longer requires cloning and linking a Rivet checkout; the documented user path installs directly from the GitHub package source.
- Added English and Chinese getting-started guides that take a new project through `doctor`, `dev`, the generated native hosts, packaging, and verification.
- The project homepage now makes **Get Started / 快速开始** the primary call to action, routes each language to its matching guide, and preserves the existing browser-language and explicit-language-override behavior.
- `raco rivet doctor` now prints actionable remediation guidance for incomplete Racket, Windows C++, and Apple developer toolchains while keeping `doctor --json` data-only for automation.
- Newly scaffolded applications include a self-guiding README with the normal edit locations, development loop, packaging commands, and English/Chinese walkthrough links.
- `raco rivet new` now prints an explicit `Next:` sequence and points developers to the generated README plus both getting-started guides.
- Deterministic embedded Racket lifecycle on macOS, including idempotent stop and restart rejection.
- Standalone Swift `RivetClient` instances now use the same one-shot lifecycle: start is reserved before the Hello read, concurrent starts are rejected, and stop/startup races cannot resurrect a stopped client.
- Typed Event schema validation and generated Swift/C++ Event APIs.
- Native identifier collision detection and language-specific codegen string escaping.
- Bounded RVT1 frame/value byte size, value nesting, total value-node count, concurrent backend and native pending requests, declared/incoming API-name size, and queued backend output.
- Racket List encoding applies the value-node budget while discovering list length instead of fully traversing oversized Lists before rejecting them; improper Lists fail explicitly without formatting the entire value.
- Typed Racket value validation applies the same List nesting and total-node budgets before encoding, avoids `list?`/`andmap` full traversals, and keeps `Any` opaque so validation itself remains bounded.
- Racket protocol encoding reports unsupported application values without formatting the object itself, so custom writers cannot amplify or replace the original codec failure.
- Synchronized request cancellation/completion ownership and non-zero UInt64 Event ID allocation; Event IDs wrap from `2^64-1` back to `1`, while terminal requests keep their pending slot until their Response/Error is admitted to the bounded output queue.
- Duplicate Request IDs and illegal inbound frame types that collide with a pending request use first-request-wins semantics, preventing a second terminal frame from consuming the original native caller's continuation; IDs become reusable after release.
- Native Windows/macOS request-ID allocators skip zero and still-pending IDs across UInt64 wraparound; cancellation is latched until its Request frame is written so Cancel cannot overtake Request on the wire.
- Native Cancel writes are linearized with pending-request ownership, so a response cannot release an ID between the final ownership check and the Cancel write and let a stale cancellation cross into a later wrapped request that reuses the same ID.
- Windows transport shutdown is serialized across concurrent `stop()` calls, blocks new Request/Cancel writes at the Shutdown boundary, and keeps the transport object alive until the native reader thread has exited before destroying its pipe handles.
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
- An opt-in Clang/libFuzzer harness exercises native RVT1 value/frame decoding under ASan and UBSan; pull requests run a bounded fuzz smoke campaign seeded from the shared golden vectors, with a reproducible per-run seed and self-contained crash/timeout/OOM payloads in CI logs.
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
