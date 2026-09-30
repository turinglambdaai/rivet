# Rivet

Build first-party native desktop apps with [Racket](https://racket-lang.org/). Use WinUI 3 on Windows, SwiftUI on macOS, and GTK4 on Linux; keep your application logic in Racket and ship a real native app instead of a WebView or a cross-platform widget layer.

[![CI](https://github.com/turinglambdaai/rivet/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/rivet/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) ![Version](https://img.shields.io/badge/version-0.3.0-C15F3C)

**English** · [中文](README.zh-CN.md)

## Quick Start

Install Rivet from the Racket Package Catalog with the `raco` from the Racket CS installation you want to embed:

```bash
raco pkg install --auto rivet
raco rivet new hello
cd hello
raco rivet doctor
raco rivet dev
```

That is the normal first-run path. `doctor` checks the native toolchain and prints actionable fixes when a required component is missing; `dev` builds and launches the current platform's first-party native host.

For a guided walkthrough, read **[Getting Started with Rivet](docs/getting-started.md)**. The installed package also includes searchable Scribble documentation. If you are developing Rivet itself, use the linked-checkout workflow in that guide instead of installing from the catalog.

## Why Rivet?

Racket is an excellent language for application logic, but there is no direct path from a Racket backend to the modern first-party desktop stacks that commercial applications increasingly use.

Rivet fills that gap:

- **First-party native UI** — WinUI 3 on Windows, SwiftUI/AppKit on macOS, GTK4 on Linux
- **Racket for application logic** — macros, pattern matching, concurrency, data processing, domain logic
- **One backend contract** — typed RPC, events, shared state, cancellation, and lifecycle over the same RVT1 protocol
- **Generated native clients** — Racket declarations become typed Swift and C++ APIs at build time
- **Embedded Racket CS** — the Racket runtime lives inside the application process; no external backend process is required
- **Exact runtime matching** — Rivet stages the installed Racket CS runtime and never silently falls back to a nearby version

Rivet is intentionally not a WebView framework and not a cross-platform widget toolkit. The Windows app remains a Windows app; the macOS app remains a macOS app.

### Hello Rivet

The Racket backend declares the API shared by both native hosts:

```racket
#lang racket/base

(require rivet/backend)

(provide start)

(define-event progress)
(define-state counter : Int64 0)

(define-rpc (greet [name : String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
```

`raco rivet build` reads the RPC and State schema and generates typed native clients. Swift gets methods such as `increment(value:)`, `getCounter()`, and `setCounter(_:)`; C++ gets their native equivalents.

### How it compares

| | Rivet | Glaze | Bezel |
|---|---|---|---|
| UI stack | **WinUI 3 / SwiftUI** | HTML/CSS/JS + WebView | Qt 6 Widgets |
| Racket role | shared backend | backend + local web server | application + bindings |
| Native widgets | **first-party OS UI** | no | Qt widgets |
| One UI codebase | no | yes | yes |
| Styling model | platform native | CSS | QSS |
| Best fit | platform-native commercial apps | web-tech desktop apps | traditional cross-platform GUI |

The three projects serve different trade-offs rather than replacing one another.

## How it works

```text
                    Racket application
                           │
             RPC / Event / State / Cancel
                           │
                    RVT1 protocol
                ┌────────┬────────┐
                │        │        │
           C++/WinRT   Swift     C++
                │        │        │
             WinUI 3  SwiftUI   GTK4
                │        │        │
             Windows   macOS    Linux
```

Racket CS runs on a dedicated runtime thread. Native UI code never manipulates Racket/Chez values directly, and Racket pointers never cross ordinary native thread boundaries. The native side only sees framed RVT1 messages and generated Swift/C++ values.

The embedding model is inspired by [Noise](https://github.com/Bogdanp/Noise), but Rivet makes the runtime contract, protocol, code generation, and lifecycle cross-platform instead of Swift-first.

See [architecture](docs/architecture.md), [protocol](docs/protocol.md), [embedding](docs/embedding.md), [typed device communication](docs/device-communication.md), [project configuration](docs/configuration.md), [system services](docs/system-services.md), [release and updates](docs/release-and-updates.md), [diagnostics](docs/diagnostics.md), [package verification](docs/package-verification.md), and [production signing](docs/production-signing.md) for the details.

## Platform status

| Capability | Windows | macOS | Linux |
|---|---|---|---|
| Native host | ✅ WinUI 3 + C++/WinRT | ✅ SwiftUI + Swift | 🧪 GTK4 + C++ |
| Embedded Racket CS | ✅ | ✅ | ✅ static runtime |
| RVT1 / Events / State / Cancel | ✅ | ✅ | ✅ |
| Typed generated client | ✅ C++ | ✅ Swift | ✅ C++ |
| `new` / `doctor` / `build` / `dev` | ✅ | ✅ | ✅ |
| `package` / `verify` | ✅ dependency audit | ✅ signing/rpath/plist audit | 🧪 directory + `ldd` audit |
| Production signing / installer | ✅ Authenticode + MSI | ✅ Developer ID + DMG | — distro-specific work remains |
| System services / secure storage | ✅ | ✅ | — |
| Real embedded-runtime CI | ✅ | ✅ | ✅ |

Windows and macOS remain the production release targets. Linux is now a developer preview with the complete daily CLI path and real embedded-runtime CI; distro-native installers, signing policy, system-service adapters, and explicit X11/Wayland policy remain before production status.

### Apple mobile foundation

| Capability | iPhone / iPad | Apple Watch |
|---|---|---|
| Portable Swift protocol/runtime | ✅ iOS/iPadOS 16+ | ✅ watchOS 9+ |
| Typed cross-device request/response | ✅ | ✅ |
| WatchConnectivity adapter | ✅ phone endpoint | ✅ watch endpoint |
| Embedded Racket CS app host | planned portable-bytecode runtime | companion mode by default |
| `raco rivet new/build/package` app flow | not yet | not yet |

The mobile targets are foundations, not a claim of finished app delivery. The phone/tablet embedded runtime and native SwiftUI scaffolds come next; watchOS deliberately starts as a typed companion to the phone-hosted backend.

## Requirements

| Dependency | Purpose |
|---|---|
| [Racket CS](https://racket-lang.org/) | application backend and embedded runtime |
| Visual Studio 2022 / Build Tools + Windows SDK | Windows host build; Windows App SDK is restored as a project package |
| Xcode command line tools / Swift | macOS host build |

Rivet discovers the exact installed Racket CS runtime, boot files, headers, and native libraries during the build. Run `raco rivet doctor` before your first `dev`; when the environment is incomplete, it prints the next remediation steps instead of only reporting `not found`.

## Development workflow

Create a project and enter the normal edit/run loop:

```bash
raco rivet new hello
cd hello
raco rivet doctor
raco rivet dev
```

The generated project contains a shared Racket backend plus native Windows, macOS, and Linux hosts. Its own `README.md` points directly to the files you normally edit.

Build and package when you are ready to leave the development loop:

```bash
raco rivet build
raco rivet package
raco rivet verify
raco rivet release
```

`build` produces the native host and staged runtime. `package` turns that output into a distributable Windows/Linux directory or a macOS `.app` bundle and verifies it before reporting success. `verify` re-audits an existing package.

For publisher-signed output, use `raco rivet package --production` with the platform signing credentials described in [docs/production-signing.md](docs/production-signing.md).

`release` adds the formal installer, independently signed update manifest, SBOM, and third-party notices. See [Release and updates](docs/release-and-updates.md); update signing keys are separate from Authenticode/Developer ID credentials.

## RPC, Event, State, Cancel

### Typed RPC

```racket
(define-rpc (lookup-user [id : Int64] : String)
  (format "user-~a" id))
```

Arguments and results are validated at the Racket boundary. Supported schema values currently include `String`, `Int64`, `Bool`, `Bytes`, `Void`, `Any`, `(List T)`, and `(Optional T)`.

### Events

```racket
(define-event download-progress)
(download-progress 75)
```

Events travel over the same RVT1 connection as RPC responses, without opening another server or port.

### Shared State

```racket
(define-state counter : Int64 0)
(state-set! counter 42)
```

Native clients can get and set the state through generated typed accessors. Updating State emits a `$state` event so the UI can react without polling.

### Cancellation

Long-running requests use RVT1 request IDs. Native clients can cancel an outstanding request; the Racket server tears down the request custodian and returns a cancellation error without killing the backend.

## CLI

```text
raco rivet new <name>              Create a Rivet application
raco rivet doctor                  Inspect Racket and native toolchains
raco rivet doctor --json           Emit machine-readable diagnostics
raco rivet clean                   Remove generated .rivet/build/dist artifacts
raco rivet build                   Compile backend, generate clients, build native host
raco rivet dev                     Build and run the current application
raco rivet package                 Create and verify a development distributable
raco rivet package --production    Create, sign, and verify a production distributable
raco rivet release                 Build installer, signed update manifest, SBOM, and notices
raco rivet release --development   Exercise release flow without platform production signing
raco rivet compliance              Generate SBOM/notices and run the license audit
raco rivet verify                  Re-verify the current packaged artifact
raco rivet verify --production     Verify production trust/notarization requirements
raco rivet help                    Show CLI help
```

## Project Structure

A generated application is intentionally simple:

```text
hello/
├── rivet.rktd
├── app/
│   └── backend.rkt
├── windows/
│   ├── App.xaml
│   ├── MainWindow.xaml
│   └── RivetHost.vcxproj
├── macos-host/
    ├── Package.swift
    └── Sources/
        └── RivetHost/
└── linux/
    ├── CMakeLists.txt
    └── src/main.cpp
```

You own the native UI source. Rivet owns the runtime bridge, protocol, code generation, and build orchestration.

`rivet.rktd` is also the source of truth for application identity, release version/build number, and the Windows/macOS minimum deployment versions. See [docs/configuration.md](docs/configuration.md).

## Repository Structure

```text
rivet/
├── rivet/                    # Racket backend, protocol and State/RPC definitions
├── rivet-cli/                # new / doctor / clean / build / dev / package / verify / codegen
├── runtime/                  # shared C++ RVT1 codec and tests
├── platform/
│   ├── windows/
│   │   ├── runtime/          # Racket CS bridge + native client
│   │   └── host/             # WinUI 3 scaffold
│   └── macos/
│       ├── Sources/          # Swift protocol/client + C embedding bridge
│       └── host/             # SwiftUI scaffold
├── tests/
└── docs/
```

## Testing

```bash
raco test tests/
cmake -S runtime -B runtime/build
cmake --build runtime/build
ctest --test-dir runtime/build
swift test --package-path platform/macos
```

CI runs the protocol implementation across Windows, macOS, and Linux, exercises real embedded Racket round trips on all three platforms, and smoke-builds, packages, and verifies generated native applications on all three desktop platforms.

## Honest gaps

- **Linux is a developer preview** — the complete daily CLI path works, but production signing, distro-native installers, system services, and compositor-specific behavior are not complete.
- **Apple mobile delivery is foundational** — the portable Swift and typed WatchConnectivity layers exist, but iOS/iPadOS/watchOS project generation, runtime packaging, signing, and store delivery are not complete.
- **Android is not implemented yet** — Jetpack Compose, JNI, portable Racket CS packaging, and Gradle integration remain separate product work.
- **Windows starts with x64** — additional architectures can be added after the runtime packaging path is stable.
- **No cross-platform declarative UI DSL** — native UI code remains SwiftUI/AppKit or WinUI 3/C++/WinRT.
- **Publisher credentials remain application-specific** — Rivet automates Authenticode and Developer ID/notarization flows, but certificates, PFX passwords, and Apple notary profiles are intentionally supplied by the application/CI environment rather than stored by Rivet.
- **The public API is still pre-1.0** — protocol compatibility is versioned, but higher-level APIs may still evolve.

## Roadmap

- [x] **Phase 1** — RVT1 protocol in Racket, C++, and Swift
- [x] **Phase 2** — embedded Racket CS on Windows and macOS
- [x] **Phase 3** — typed RPC, Event, State, Cancel, generated Swift/C++ clients
- [x] **Phase 4** — `new` / `doctor` / `build` / `dev` / `package`
- [x] **Phase 5** — package verification, production signing/notarization entry points, and tag-driven release engineering
- [ ] **Phase 6** — broader architectures, richer schema/codegen types, and long-term protocol compatibility tooling

## License

Licensed under the [MIT License](LICENSE).
