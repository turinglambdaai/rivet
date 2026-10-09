# Getting Started with Rivet

This guide takes a fresh machine from “Rivet is installed” to a running native application and a distributable build. The starter project is intentionally small: a Racket backend plus native WinUI 3, SwiftUI, and GTK4 hosts.

## 1. Install Rivet

Install from the Racket Package Catalog with the `raco` from the Racket CS installation you want Rivet to embed. Rivet requires Racket 9.0 or newer with the CS runtime; the legacy BC engine is not supported:

```bash
raco pkg install --auto rivet
```

If you are developing Rivet itself, use a linked checkout instead:

```bash
git clone https://github.com/turinglambdaai/rivet.git
cd rivet
raco pkg install --auto --name rivet --link "$(pwd)"
```

Confirm the CLI is available:

```bash
raco rivet help
```

## 2. Create your first app

```bash
raco rivet new hello-rivet
cd hello-rivet
```

The generated project contains:

```text
hello-rivet/
├── rivet.rktd              # app identity, backend entry point, deployment targets
├── app/backend.rkt         # shared Racket application logic
├── windows/                # WinUI 3 application
├── macos-host/             # SwiftUI application
└── linux/                  # GTK4 application
```

You own the native UI source. Rivet owns the embedded-runtime bridge, RVT1 protocol, client generation, build orchestration, packaging, and verification.

## 3. Let `doctor` check the machine

Run:

```bash
raco rivet doctor
```

A healthy machine ends with:

```text
rivet: toolchain looks usable
```

If something required is missing, `doctor` prints a **Fix next** section with the action to take. Fix the reported dependency and rerun the command.

Typical requirements are:

- **Windows:** Racket CS, Visual Studio 2022 or Build Tools with Desktop development with C++, and a Windows SDK. Rivet restores the Windows App SDK package during the native build.
- **macOS:** Racket CS plus the Apple developer command-line/Xcode toolchain.
- **Linux:** CMake, pkg-config, a C++20 toolchain, GTK4 development files, zlib, LZ4, curses, and an embeddable static `libracketcs.a`. Set `RIVET_RACKET_LIBRARY` and `RIVET_RACKET_BOOT_DIR` when those artifacts are outside the active Racket installation.

For CI or developer agents, use machine-readable diagnostics:

```bash
raco rivet doctor --json
```

## 4. Run the starter application

```bash
raco rivet dev
```

Rivet will compile the backend, generate the native client, build the current platform host, stage the exact Racket CS runtime, and launch the application.

The starter window shows a counter. Clicking **Increment in Racket** updates shared state through the embedded Racket backend. That small interaction proves the full path is working:

```text
native UI → generated client → RVT1 → embedded Racket CS → State → native UI
```

## 5. Make your first backend change

Open `app/backend.rkt`. The starter backend already declares an event and shared state:

```racket
(define-event notification : String)
(define-state counter : Int64 0)
```

Add a typed RPC:

```racket
(define-rpc (greet [name : String] : String)
  (format "Hello, ~a!" name))
```

Save the file and run:

```bash
raco rivet dev
```

During the build, Rivet reads the backend schema and regenerates the typed native API. On macOS the generated Swift client exposes native async methods; on Windows the generated C++ API exposes completion-driven methods; Kotlin gets a typed suspend client at `.rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt` for Android applications. You do not hand-write protocol frames or marshal Racket values across UI threads.

The generated project already contains `rivet-schema.json`. Commit that compatibility baseline and make CI check it; refresh it only when an API change is intentional:

```bash
raco rivet schema --output rivet-schema.json
raco rivet schema check rivet-schema.json --json
```

The second command permits new declarations and fails for removed or changed RPC, Event, State, Record, or existing Enum contracts.

## 6. Where to edit the UI

### Windows

Start with:

```text
windows/MainWindow.xaml
windows/MainWindow.xaml.cpp
```

`MainWindow.xaml` is ordinary WinUI 3 XAML. `MainWindow.xaml.cpp` shows how the starter host starts the embedded backend and calls generated State methods without blocking the UI thread.

### macOS

Start with:

```text
macos-host/Sources/RivetHost/ContentView.swift
macos-host/Sources/RivetHost/RivetHostApp.swift
```

`ContentView.swift` is ordinary SwiftUI. The starter `AppModel` owns the embedded backend and demonstrates asynchronous access to generated State methods.

### Linux

Start with `linux/src/main.cpp`. It is an ordinary GTK4 application and uses the same generated, completion-driven C++ API as the Windows host, bound to Rivet's Linux embedded runtime.

The scaffold calls `rivet::linux_ui::ApplyTheme()` before creating widgets.
Plain GTK4 desktops can report a portal/GSettings color scheme that disagrees
with the effective `gtk-theme-name` variant; the helper resolves both signals,
pins the GTK light/dark variant, and returns the palette application CSS should
use. Applications with a theme setting can pass `ThemePreference::light`,
`ThemePreference::dark`, or `ThemePreference::system` and reapply their CSS
from the returned `ColorScheme`. Keep this call on GTK's main thread.

Rivet intentionally does **not** introduce a cross-platform UI DSL. Use the first-party UI framework normally and keep reusable application/domain logic in Racket.

Application data such as images, templates, and localization files can be declared once in `rivet.rktd` and read from Racket with `resource-path`. Rivet preserves relative paths across development and packaged layouts; see [project configuration](configuration.md#application-resources-and-icons).

## 7. When the application needs another ecosystem

Start with `raco rivet inspect --json`; its `capability-sourcing` object gives
coding agents the same decision order as the generated `AGENTS.md`:

| Need | Preferred boundary |
|---|---|
| Portable application logic | Racket standard library or maintained Package Catalog package |
| UI or operating-system behavior | WinUI, SwiftUI/AppKit, or GTK native host |
| Frequent low-latency calls to a stable C ABI | Small checked `ffi/unsafe` wrapper |
| Bounded work already implemented by a mature tool | `subprocess`/`system*` with executable + argv |
| Persistent runtime, streaming, unstable ABI, or crash isolation | Authenticated and versioned local sidecar |
| Small or security-critical missing primitive | Owned implementation with conformance tests |

Library availability is therefore a boundary-selection problem, not a binary
test of whether Racket alone already implements everything. Every choice still
needs license, Racket CS, platform/architecture, versioning, resource-limit,
packaging, clean-machine, and offline checks. See
[capability sourcing](agent-native.md#capability-sourcing) for the complete
workflow and CLI/FFI safety rules.

## 8. Build, package, and verify

When the app is ready to leave the development loop:

```bash
raco rivet build
raco rivet package
raco rivet verify
```

`package` verifies the generated development distributable before reporting success. `verify` can audit it again later.

For a publisher-trusted production artifact:

```bash
raco rivet package --production
raco rivet verify --production
```

Production mode uses application-owned signing credentials. See [production signing](production-signing.md) before configuring secrets in CI.

For a complete product release, configure a separate Ed25519 update key and run `raco rivet release`. It adds installer creation (MSI, DMG, or the Ed25519-signed Linux tarball), the signed channel manifest, SBOM, and third-party notices. A product that intentionally has no update channel uses `raco rivet release --without-updates`; installer signing and compliance artifacts are still produced. See [release and updates](release-and-updates.md).

## 9. The normal Rivet workflow

For day-to-day development, the commands worth remembering are only:

```bash
raco rivet doctor     # when setting up or diagnosing a machine
raco rivet dev        # normal edit/build/run loop
raco rivet package    # create a distributable
raco rivet verify     # audit an existing distributable
raco rivet release    # create the full signed release set
```

Then read the deeper documentation only when you need it:

- [Architecture](architecture.md)
- [Continuous integration](ci.md)
- [Project configuration](configuration.md)
- [Diagnostics](diagnostics.md)
- [Protocol](protocol.md)
- [Embedding model](embedding.md)
- [Package verification](package-verification.md)
- [Production signing](production-signing.md)
- [Release and updates](release-and-updates.md)
- [System services](system-services.md)

## Troubleshooting rule of thumb

Start with `raco rivet doctor`. If the toolchain is healthy but `dev`, `build`, or `package` fails, keep the first `rivet: error:` message and the native compiler output immediately around it. Rivet aims to fail at the earliest actionable boundary rather than hide native build failures behind generic errors.
