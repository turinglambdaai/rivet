# Architecture

Rivet is a native desktop application foundation for Racket. It embeds one Racket CS runtime in the application process and connects it to the operating system's first-party UI framework.

The central design rule is that **Racket is the shared application/runtime layer, not the widget toolkit**.

```text
                     Application logic
                          Racket
                            │
                 typed RPC / events / state
                            │
                  Rivet protocol (RVT1)
                            │
                  native runtime client
                    ┌───────┴───────┐
                    │               │
                C++/WinRT         Swift
                    │               │
                 WinUI 3       SwiftUI/AppKit
                    │               │
                 Windows           macOS
```

## Why not a direct Noise port?

Noise proves that embedding Racket CS in a native application can work well. Its strongest ideas are worth keeping:

- embed Racket instead of launching a separate Racket process;
- compile application code into an embedded module bundle;
- keep backend work away from the UI thread;
- use request identifiers so multiple backend calls can be outstanding;
- define data/RPC boundaries rather than sharing runtime objects across languages.

Rivet changes the center of gravity. The protocol and lifecycle are platform-neutral first; Swift and C++ are peer clients. The framework does not define its core concepts in Swift and then translate them to Windows.

## Processes and threads

A normal Rivet application has one process and one Racket CS runtime.

### Windows

```text
WinUI UI thread
    │
    ├── Backend::call(...)
    │      │
    │      └── request frame -> anonymous pipe
    │
    ├── UI remains responsive
    │
    └── DispatcherQueue <- completed native future

Racket worker thread
    │
    ├── racket_boot
    ├── load core.zo
    ├── dynamic-require app entry
    └── racket_apply -> serve-fds
              │
              ├── Racket request thread A
              ├── Racket request thread B
              └── Racket request thread C

Native reader thread
    │
    └── response frame -> promise by request-id
```

The WinUI thread never owns or accesses a Racket/Chez value. The worker thread enters Racket through the documented Racket CS embedding API. Protocol values are copied across the boundary.

### macOS

The macOS host follows the same logical model:

```text
MainActor / SwiftUI
       │
       └── Rivet client
              │
       protocol transport
              │
       Racket worker
```

The Swift implementation is intentionally not the framework's specification. `docs/protocol.md` and the Racket modules are the specification.

## Runtime ownership

Rivet treats a Racket runtime as process-scoped infrastructure:

1. the native host resolves an **exact matching** Racket CS runtime and boot files;
2. one dedicated native worker boots Racket CS;
3. the compiled application bundle is loaded;
4. the configured module and entry procedure are dynamically required;
5. the entry receives native file descriptors and calls `serve-fds`;
6. Shutdown terminates the server cleanly;
7. the host joins runtime/reader threads before native UI teardown completes.

A `Backend` object cannot be restarted after shutdown in v0. This is intentional: restart semantics for an in-process Scheme runtime are easy to make subtly unsafe and are not needed for application lifecycle.

## Transport

Windows and macOS both use two in-process pipes with the same logical direction:

```text
Native request writer ─────────► Racket request reader
Native response reader ◄──────── Racket response writer
```

The protocol is not pipe-specific. The C++ runtime exposes an abstract `Transport`; Swift uses `FileHandle` over `Pipe`. Named pipes, in-memory transports, or other primitives can be added without changing RPC framing.

## RPC concurrency

The native client allocates a monotonically increasing 64-bit request ID and inserts a native promise into a pending table before writing a Request frame.

The Racket server creates a custodian and lightweight Racket thread for each request. Completed responses are funneled through one writer thread to guarantee that frames cannot interleave.

Cancellation shuts down the request custodian and responds with an Error frame. Native callers never receive a raw Racket exception; errors cross the protocol as data.

## Data ownership

No native language binding retains a raw Racket value across calls. This avoids coupling ordinary UI code to Chez Scheme's collector and object movement rules.

Rivet v1 begins with a small value model:

- null/void
- Bool
- Int64
- UTF-8 String
- Bytes
- List

Typed generated clients are layered on top of this codec. The current schema supports `String`, `Int64`, `Bool`, `Bytes`, `Void`, `Any`, `List`, and `Optional`. Optional values reuse the Null/Void wire tag, so these schema types do not require framing changes. Records and enums remain future schema extensions.

## UI strategy

Rivet deliberately does **not** provide a fake common widget toolkit in its first layer.

Windows applications should be able to use everything WinUI 3 exposes. macOS applications should be able to use everything SwiftUI/AppKit exposes. A future Racket declarative UI layer may map a useful common subset to each renderer, but it is deliberately outside the 0.1 runtime contract and must not prevent platform-native escape hatches.

This differs from:

- Glaze: shared web UI rendered in WebViews;
- Bezel: one shared Qt widget API;
- Rivet: shared Racket application/runtime logic with first-party platform UI.

## Build artifacts

Application Racket code is compiled with `raco ctool --mods` into a bundle such as `core.zo`. Transitive module dependencies are embedded in that bundle. Runtime resources are collected separately using `raco ctool --runtime` when packaging.

The host bundles:

- the exact matching Racket CS runtime;
- `petite.boot`, `scheme.boot`, `racket.boot`;
- compiled `core.zo`;
- any runtime files collected by `raco ctool`;
- the native platform executable and resources.

Target machines should not need a user-installed Racket distribution.
