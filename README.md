# Rivet

**Build native desktop apps with Racket.**

Rivet embeds Racket CS behind real platform-native user interfaces:

- **Windows:** WinUI 3 with C++/WinRT
- **macOS:** SwiftUI / AppKit
- **Shared core:** Racket business logic, typed RPC, events, lifecycle, and application state

Rivet is not a WebView framework and it is not a cross-platform widget toolkit. Each platform uses its native UI stack while sharing the same Racket backend and protocol.

> Status: early architecture and runtime work. The public API is not stable yet.

## Direction

```text
                    Racket application
                          │
                RPC / events / state
                          │
                Rivet protocol + runtime
                    ┌─────┴─────┐
                    │           │
                 Windows      macOS
                 WinUI 3      SwiftUI
                C++/WinRT      Swift
```

The runtime model is inspired by the strongest ideas in Bogdan Popa's Noise project—embed Racket CS, keep Racket work off the UI thread, define typed boundaries, and generate native clients—but Rivet is designed from the start around a platform-neutral protocol instead of a Swift-first API.

## Intended developer experience

```bash
raco pkg install rivet

raco rivet new hello
cd hello
raco rivet doctor
raco rivet dev
raco rivet build
raco rivet package
```

The first milestone is smaller: make the runtime, protocol, CLI, and a real WinUI 3 ↔ Racket round trip solid before adding higher-level UI abstractions.

## Application code

The target API looks like this:

```racket
#lang racket/base

(require rivet/backend
         rivet/types)

(define-rpc (greet [name : String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))
```

The same Racket module is consumed by generated Swift and C++ clients.

## Architecture rules

1. **One Racket runtime per process.** Runtime ownership and shutdown are explicit.
2. **The UI thread never becomes the Racket server thread.** WinUI and SwiftUI stay responsive.
3. **The wire protocol is platform-neutral.** Swift and C++ are peers, not separate implementations of the framework.
4. **Exact Racket runtime matching.** Boot files and Racket CS libraries must match; Rivet never silently falls back to a nearby Racket release.
5. **Native UI remains native.** Rivet does not emulate WinUI on macOS or SwiftUI on Windows.
6. **Keep the first layer small.** Runtime + RPC + events first; declarative native UI can come later.

See [docs/architecture.md](docs/architecture.md) and [docs/protocol.md](docs/protocol.md).

## Repository layout

```text
rivet/
├── rivet/                 # Racket library
├── rivet-cli/             # CLI implementation
├── runtime/               # native runtime / protocol contract
├── platform/
│   ├── windows/           # C++/WinRT + WinUI 3 host
│   └── macos/             # Swift host
├── codegen/               # generated native client pipeline
├── templates/             # `raco rivet new`
├── examples/
├── tests/
└── docs/
```

## Relationship to other Racket desktop approaches

- **Glaze** — Racket + WebView/web UI.
- **Bezel** — Racket + Qt 6.
- **Rivet** — Racket + the operating system's native UI framework.

Those are deliberately different trade-offs.

## License

MIT. See [LICENSE](LICENSE).
