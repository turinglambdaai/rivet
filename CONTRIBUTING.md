# Contributing

Rivet is pre-1.0, so keep changes small, testable, and compatible with the architecture in `docs/`.

For Racket/runtime changes, run `raco test tests/`. For the shared C++ protocol, configure `runtime/` with `RIVET_BUILD_TESTS=ON` and run CTest. On macOS, run `swift test --package-path platform/macos`.

Platform-specific UI code belongs under `platform/windows` or `platform/macos`. Do not move platform UI semantics into RVT1. Protocol changes require matching Racket, C++, Swift, tests, and `docs/protocol.md` updates.

Prefer a focused pull request with a clear failure mode and regression test. Avoid adding dependencies when the platform or Racket standard libraries already provide the required primitive.
