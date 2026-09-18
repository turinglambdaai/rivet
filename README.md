# Rivet

**Build native desktop apps with Racket.**

Rivet embeds Racket CS behind first-party native desktop UI:

- **Windows:** WinUI 3 + C++/WinRT
- **macOS:** SwiftUI/AppKit + Swift
- **Shared backend:** Racket business logic, typed RPC, events, cancellation, lifecycle, and code generation

Rivet is not a WebView framework and not a cross-platform widget toolkit. Each platform keeps its native UI stack while sharing one Racket backend contract.

> Status: pre-1.0. The runtime and CLI are usable for early development, but the public API can still change.

## Developer experience

```bash
raco pkg install rivet

raco rivet new hello
cd hello

raco rivet doctor
raco rivet dev
raco rivet build
raco rivet package
```

`new` creates both a WinUI 3 host and a SwiftUI host. `build` recompiles the Racket backend, regenerates typed native clients, resolves the exact installed Racket CS runtime, and builds the host for the current OS. `package` stages a distributable Windows directory or a macOS `.app` bundle.

## Racket backend

```racket
#lang racket/base

(require rivet/backend)

(provide start)

(define-event progress)

(define-rpc (greet [name : String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define-rpc (do-work [value : Int64] : Int64)
  (progress value)
  (add1 value))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
```

Rivet records the RPC schema and validates arguments/results at the Racket boundary. `raco rivet build` generates native wrappers, so Swift and C++ call typed methods instead of spelling RPC names and decoding wire values manually.

Current schema types are `String`, `Int64`, `Bool`, `Bytes`, `Void`, `Any`, `(List T)`, and `(Optional T)`.

## Runtime model

```text
                    Racket application
                          │
               typed RPC / events
                          │
                    RVT1 protocol
                    ┌─────┴─────┐
                    │           │
                 Windows      macOS
                 C++/WinRT     Swift
                    │           │
                  WinUI 3     SwiftUI
```

The runtime model takes inspiration from Bogdan Popa's Noise project—embed Racket CS, isolate the Racket runtime from the UI thread, and define a typed native boundary—but Rivet makes the protocol and lifecycle platform-neutral first.

## Architecture rules

1. **One embedded Racket CS runtime per application process.**
2. **The native UI thread never becomes the Racket server thread.**
3. **RVT1 is shared by Racket, C++, and Swift.**
4. **Racket runtime artifacts must match exactly.** Rivet never silently chooses a nearby release.
5. **Racket/Chez pointers never cross ordinary native thread boundaries.**
6. **Native UI remains native.** WinUI and SwiftUI/AppKit stay fully available.
7. **Generated clients are derived from the Racket RPC schema on every build.**

See [docs/architecture.md](docs/architecture.md), [docs/protocol.md](docs/protocol.md), and [docs/embedding.md](docs/embedding.md).

## Repository layout

```text
rivet/
├── rivet/                    # Racket protocol/backend library
├── rivet-cli/                # new/doctor/build/dev/package + codegen
├── runtime/                  # shared C++ RVT1 implementation/tests
├── platform/
│   ├── windows/
│   │   ├── runtime/          # Racket CS + RVT1 native client
│   │   └── host/             # WinUI 3 scaffold
│   └── macos/
│       ├── Sources/          # Swift RVT1 + embedding bridge
│       └── host/             # SwiftUI scaffold
├── tests/
└── docs/
```

## Relationship to other Racket desktop approaches

- **Glaze** — Racket + WebView/web UI.
- **Bezel** — Racket + Qt.
- **Rivet** — Racket + the operating system's native UI framework.

These projects intentionally serve different trade-offs.

## Current limits

The first supported Windows target is x64. macOS packaging currently performs ad-hoc hardened-runtime signing; production Developer ID signing and notarization are deployment concerns that can be added without changing the runtime protocol. Rivet does not currently provide a cross-platform declarative widget DSL.

## License

MIT. See [LICENSE](LICENSE).
