# Getting Started with Rivet

This guide takes a fresh machine from “Rivet is installed” to a running native application and a distributable build. The starter project is intentionally small: a Racket backend plus first-party WinUI 3 and SwiftUI hosts.

## 1. Install Rivet

Install directly from the GitHub repository with the `raco` from the Racket CS installation you want Rivet to embed:

```bash
raco pkg install --auto https://github.com/turinglambdaai/rivet.git
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
└── macos-host/             # SwiftUI application
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

- **Windows:** Racket CS, Visual Studio 2022 or Build Tools with Desktop development with C++, a Windows SDK, and Windows App SDK.
- **macOS:** Racket CS plus the Apple developer command-line/Xcode toolchain.

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

During the build, Rivet reads the backend schema and regenerates the typed native API. On macOS the generated Swift client exposes native async methods; on Windows the generated C++ API exposes completion-driven methods. You do not hand-write protocol frames or marshal Racket values across UI threads.

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

Rivet intentionally does **not** introduce a cross-platform UI DSL. Use the first-party UI framework normally and keep reusable application/domain logic in Racket.

## 7. Build, package, and verify

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

## 8. The normal Rivet workflow

For day-to-day development, the commands worth remembering are only:

```bash
raco rivet doctor     # when setting up or diagnosing a machine
raco rivet dev        # normal edit/build/run loop
raco rivet package    # create a distributable
raco rivet verify     # audit an existing distributable
```

Then read the deeper documentation only when you need it:

- [Architecture](architecture.md)
- [Project configuration](configuration.md)
- [Diagnostics](diagnostics.md)
- [Protocol](protocol.md)
- [Embedding model](embedding.md)
- [Package verification](package-verification.md)
- [Production signing](production-signing.md)

## Troubleshooting rule of thumb

Start with `raco rivet doctor`. If the toolchain is healthy but `dev`, `build`, or `package` fails, keep the first `rivet: error:` message and the native compiler output immediately around it. Rivet aims to fail at the earliest actionable boundary rather than hide native build failures behind generic errors.
