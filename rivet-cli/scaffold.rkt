#lang racket/base

(require racket/file
         racket/path
         racket/runtime-path
         "codegen.rkt"
         "project.rkt")

(provide create-project!)

(define-runtime-path rivet-root "..")

(define (safe-project-name? s)
  (regexp-match? #px"^[A-Za-z][A-Za-z0-9_-]*$" s))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'error (lambda (out) (display text out))))

(define backend-template
  #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-event notification : String)
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (notify [message String] : Void)
  (notification message)
  (void))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
  )

(define (starter-readme name)
  (format
   (string-append
    "# ~a\n\n"
    "A first-party native desktop app powered by Racket and Rivet.\n\n"
    "## Start here\n\n"
    "```bash\n"
    "raco rivet inspect --json\n"
    "raco rivet schema --json\n"
    "raco rivet doctor\n"
    "raco rivet dev\n"
    "```\n\n"
    "`doctor` checks the local Racket/native toolchain and prints actionable fixes when something required is missing. `dev` rebuilds the Racket backend, regenerates the typed native client, builds the current platform host, and launches the app.\n\n"
    "## Edit the app\n\n"
    "- Shared Racket logic: `app/backend.rkt`\n"
    "- Windows UI: `windows/MainWindow.xaml` and `windows/MainWindow.xaml.cpp`\n"
    "- macOS UI: `macos-host/Sources/RivetHost/ContentView.swift` and `RivetHostApp.swift`\n"
    "- Linux UI: `linux/src/main.cpp` (GTK4)\n"
    "- Packaged application resources and icons: configure `resources`, `windows-icon`, and `macos-icon` in `rivet.rktd`\n"
    "- App identity/deployment targets: `rivet.rktd`\n"
    "- Versioned public API baseline: `rivet-schema.json`\n\n"
    "## When Racket does not already have the capability\n\n"
    "Run `raco rivet inspect --json` and read `capability-sourcing`. Prefer a built-in or maintained Racket package; keep platform-owned features in the native host; use a small safe FFI wrapper for a stable C ABI; use an argv-based subprocess for coarse-grained tools; reserve a sidecar for persistent or crash-isolated runtimes. The generated `AGENTS.md` contains the safety and packaging checks.\n\n"
    "## Ship a build\n\n"
    "```bash\n"
    "raco rivet build\n"
    "raco rivet package\n"
    "raco rivet verify\n"
    "```\n\n"
    "Full tutorial: https://github.com/turinglambdaai/rivet/blob/main/docs/getting-started.md\n"
    "中文教程: https://github.com/turinglambdaai/rivet/blob/main/docs/getting-started.zh-CN.md\n"
    "Rivet website: https://rivet.jrtx.site\n")
   name))

(define starter-agents
  #<<AGENTS
# Rivet agent contract

Human-first. Agent-native. Local by design.

## Start every task here

```bash
raco rivet inspect --json
raco rivet doctor --json
```

`inspect` is the machine-readable project map. It identifies the shared Racket
backend, each native UI edit point, platform maturity, generated directories,
and safe lifecycle commands. `doctor` reports the exact local toolchain and
returns a failing exit status when the current host is not usable.

## Architecture boundary

- Keep shared application and domain logic in `app/backend.rkt`.
- Keep Windows UI native in WinUI 3 / C++/WinRT under `windows/`.
- Keep macOS UI native in SwiftUI/AppKit under `macos-host/`.
- Keep Linux UI native in GTK4 under `linux/`.
- Do not introduce a cross-platform UI DSL or bypass RVT1 with an ad-hoc IPC.
- iOS/iPadOS/watchOS and Android are foundation targets until their
  generated app, embedding, packaging, signing, and device workflows exist.

## Capability sourcing

When a feature is not already present, do not reject Racket or add another
runtime by reflex. Read `capability-sourcing` from `inspect --json`, then choose
the narrowest boundary that fits:

1. Prefer a Racket built-in or maintained package. Discover candidates with
   `raco docs <term>`, `raco pkg show`, and
   `raco pkg catalog-show --all --only-names`; inspect a candidate with
   `raco pkg catalog-show --modules <package>`.
2. Put UI, lifecycle, accessibility, notification, device, and other
   platform-owned behavior in the first-party native host.
3. Use FFI for a stable C ABI that needs frequent, low-latency in-process
   calls. Hide `ffi/unsafe` behind a small safe module with explicit ownership,
   callback, thread, ABI, and native-library packaging rules.
4. Use `subprocess` or `system*` for a mature executable doing coarse-grained
   work. Pass an executable and argv directly; never construct a shell command.
   Add a version probe, timeout, bounded/concurrently drained output, exit-code
   handling, cancellation, packaging, and license checks.
5. Use a sidecar only for a persistent runtime, streaming workload, unstable
   ABI, or required crash isolation. Own authentication, protocol versioning,
   resource limits, restart/shutdown, packaging, and offline behavior.
6. Implement the capability only when it is small or security-critical and
   owning it is cheaper than owning the dependency boundary.

For every choice, verify Racket 9.0 CS support, license/redistribution terms,
all target OS/architectures, upstream maintenance, reproducible installation,
failure behavior, packaged dependency closure, and a clean-machine smoke test.

## Ownership

Source you may edit:

- `app/`
- `windows/`
- `macos-host/`
- `linux/`
- `rivet.rktd`
- `rivet-schema.json` when an API compatibility break is intentional
- declared application resources

Generated output you should not hand-edit:

- `windows/GeneratedBackend.hpp`
- `macos-host/Sources/RivetHost/GeneratedBackend.swift`
- `linux/GeneratedBackend.hpp`
- `.rivet/`
- `build/`
- `dist/`
- `windows/Generated Files/`
- `windows/obj/`
- `windows/RivetHost/`
- `macos-host/.build/`

`raco rivet build` regenerates the typed clients. Use `raco rivet clean` to
remove transient build output while keeping the generated client sources that
make the native API reviewable.

## Verification loop

This project includes a source-controlled `rivet-schema.json` API baseline.
Refresh it only after deliberately changing the public backend schema:

```bash
raco rivet schema --output rivet-schema.json
```

Before accepting later API changes, run the compatibility gate. Adding a new
RPC, Event, State, Record, or Enum type is compatible; removing one or changing
a type, argument order, result, Record field/order, or an existing Enum's
cases/order is breaking:

```bash
raco rivet schema check rivet-schema.json --json
```

```bash
raco rivet build
raco rivet dev
raco rivet package
raco rivet verify
```

After changing RPC, Event, State, Record, or Enum declarations, run the
compatibility gate and rebuild before editing code that consumes generated native APIs.
Update the baseline only when a breaking change is intentional and governed by
the application's release policy. Preserve the first `rivet: error:` line and
nearby compiler output when diagnosing a failure.
AGENTS
  )

(define (create-project! name [parent (current-directory)])
  (unless (safe-project-name? name)
    (raise-arguments-error 'rivet-new
                           "invalid project name; use letters, digits, '-' or '_'"
                           "name"
                           name))
  (define root (build-path parent name))
  (when (or (directory-exists? root) (file-exists? root))
    (raise-arguments-error 'rivet-new "destination already exists" "path" root))

  (make-directory* root)
  (write-text (build-path root "README.md") (starter-readme name))
  (write-text (build-path root "AGENTS.md") starter-agents)
  (write-text
   (build-path root "rivet.rktd")
   (format
    "#hasheq((name . ~s) (display-name . ~s) (version . ~s) (build . ~s) (identifier . ~s) (release-channel . stable) (url-schemes . ()) (file-associations . ()) (resources . ()) (device-rpcs . ()) (macos-min-version . ~s) (windows-min-version . ~s) (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1))\n"
    name
    name
    default-project-version
    default-project-build
    (default-project-identifier name)
    default-macos-min-version
    default-windows-min-version))
  (write-text (build-path root "app" "backend.rkt") backend-template)
  (write-text
   (build-path root ".gitignore")
   (string-append
    ".rivet/\n"
    "build/\n"
    "dist/\n"
    "windows/Generated Files/\n"
    "windows/obj/\n"
    "windows/RivetHost/\n"
    "macos-host/.build/\n"
    ".DS_Store\n"))

  (define windows-template (build-path (simplify-path rivet-root #t) "platform" "windows" "host"))
  (unless (directory-exists? windows-template)
    (error 'rivet-new "Windows host template is missing: ~a" windows-template))
  (copy-directory/files windows-template (build-path root "windows"))

  (define macos-template (build-path (simplify-path rivet-root #t) "platform" "macos" "host"))
  (unless (directory-exists? macos-template)
    (error 'rivet-new "macOS host template is missing: ~a" macos-template))
  ;; Keep the app host directory distinct from Rivet's own platform/macos
  ;; package. SwiftPM uses the final path element as local package identity.
  (copy-directory/files macos-template (build-path root "macos-host"))

  (define linux-template (build-path (simplify-path rivet-root #t) "platform" "linux" "host"))
  (unless (directory-exists? linux-template)
    (error 'rivet-new "Linux host template is missing: ~a" linux-template))
  (copy-directory/files linux-template (build-path root "linux"))
  ;; A fresh project starts with a usable compatibility gate. Builds never
  ;; rewrite this source-controlled baseline; applications update it only when
  ;; an API change is deliberate.
  (write-schema-snapshot! (load-project root) (build-path root "rivet-schema.json"))
  root)
