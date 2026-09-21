# Changelog

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
