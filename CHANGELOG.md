# Changelog

## 0.2.0

Rivet 0.2 hardens the native runtime contract and release path while preserving the existing WinUI 3 / SwiftUI architecture.

- Deterministic embedded Racket lifecycle on macOS, including idempotent stop and restart rejection.
- Typed Event schema validation and generated Swift/C++ Event APIs.
- Native identifier collision detection and language-specific codegen string escaping.
- Bounded RVT1 frame/value byte size, value nesting, total value-node count, concurrent backend requests, declared/incoming API-name size, and queued backend output.
- Synchronized request cancellation/completion ownership and Event ID allocation; terminal requests keep their pending slot until their Response/Error is admitted to the bounded output queue.
- Backend reader/writer supervision propagates output-port failure and stops producers instead of leaving the server blocked behind a dead writer.
- Request-local handling for malformed application RPC requests and response-serialization failures, with bounded backend Error diagnostics that cannot consume terminal-response ownership before encoding succeeds.
- State initial values and updates are preflighted as complete `$state` Events, so serialization failures cannot partially commit backend state without notifying native clients.
- Application version, build, display-name, identifier, and Windows/macOS minimum-version metadata are centralized in `rivet.rktd` with backwards-compatible defaults.
- Shared RVT1 golden vectors consumed by Racket, C++, and Swift tests.
- Strict UTF-8 validation and unknown message-type rejection across protocol implementations.
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
