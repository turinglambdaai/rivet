# Changelog

## Unreleased

- Prefer native 64-bit MSBuild when discovering Visual Studio, preventing the
  32-bit host compiler from exhausting its address space on WinUI ARM64 builds.
- Add an opt-in Linux `InstallShutdownHook` for SIGTERM/SIGINT. Its
  async-signal-safe self-pipe hands graceful state flushing to a normal watcher
  thread, while a repeated signal still terminates a stuck shutdown.
- Compile the Racket backend dependency graph with `raco make` before creating
  `core.zo`, so a same-length edit to a transitive source module cannot leave
  stale bytecode in a successful native build.
- Add the Linux tray contract: `rivet::system::TrayIcon` hosts an
  org.kde.StatusNotifierItem with a com.canonical.dbusmenu menu over the
  session bus (GDBus), the pairing every desktop watcher serves (GNOME via
  the AppIndicator extension, KDE natively). The opt-in stays an application
  decision — `TrayIcon::available()` and the `tray` capability report a
  reachable watcher; the icon, tooltip, and flat menu update in place, and
  the watcher is re-registered automatically when GNOME Shell or the
  extension reloads. Verified end to end against the real desktop watcher
  (registration, property reads, menu layout, click dispatch) plus the
  graceful no-watcher path in an isolated D-Bus session.
- Add optional human-readable `publisher` project metadata and use it for the
  Windows MSI `Manufacturer`/Apps & Features Publisher value. Legacy projects
  fall back to `display-name` instead of exposing a reverse-DNS identifier.
- Keep macOS development and test executables outside an `.app` bundle from
  entering `UNUserNotificationCenter`, whose missing bundle identity otherwise
  raises an uncatchable Objective-C exception. Notification availability is now
  explicit; authorization returns `false` and delivery throws a catchable error.
- Normalize Swift declaration keywords such as `init` and `public` before
  emitting client APIs, and put both source declarations plus the generated
  identifier in the first line of native-name collision errors.
- Add provider-neutral, layer-attributed JSONL diagnostics across the Racket
  backend, C++/Swift native clients, transports, and embedding bridges. Records
  identify lifecycle/RPC boundaries, status, last RVT1 event, and request id;
  stderr defaults and injectable sinks keep logging dependencies out of the
  runtime and leave the RVT1 wire contract unchanged.
- Launch packaged GUI artifacts as the final verification gate when a graphical
  session is available. The executable starts from an unrelated temporary
  directory, must remain alive for five seconds, and is then terminated;
  premature exit reports bounded stdout/stderr. Headless environments report
  an explicit skip, and `package`/`verify --skip-launch-smoke` provide an
  intentional override without disabling structural or signature checks.
- Generate application identity from `rivet.rktd` for every native client and
  stage the same values for Racket through `rivet/app-info`. Swift, C++, and
  Kotlin now receive display name, version, build, identifier, and release
  channel without app-local copies; the generated macOS window title uses the
  display name instead of the `RivetHost` process name.
- Make the centralized macOS embedded-runtime configuration select its staged
  resource root before Racket starts, so packaged backends can load foreign
  dependencies such as libgmp, libcrypto, and libssl regardless of the launch
  process's original working directory. The real embedded round-trip now loads
  `rivet/distribution` to keep this dependency path covered in CI.
- Generate a default-deny Apple companion API from the shared Racket schema.
  Projects explicitly list `device-rpcs`; Rivet emits Codable request/response
  types, typed `RivetDeviceClient` methods, and phone-side
  `registerGeneratedBackend` routing, records export compatibility in schema
  snapshots, rejects `Any`, and cross-compiles the generated surface for iOS
  and watchOS in CI.
- Centralize the canonical macOS embedded-runtime layout probe in
  `EmbeddedRacketConfiguration.resolvedDefault`. Generated and reference hosts
  now select packaged `Contents/Resources` or staged development layouts
  without duplicating app-side boot/core path discovery.

## 0.5.0

- Give Windows installers a per-product identity and desktop presence. The WiX installer now derives each project's `UpgradeCode` from its identifier under a fixed Rivet namespace — the previous shared hardcoded code made two Rivet applications treat each other as upgrades and silently replace one another — and authors start-menu (in a per-app folder) and desktop shortcuts pointing at `RivetHost.exe`, removing the start-menu folder on uninstall. Shortcut components carry machine-scoped registry key paths, display names and identifiers stay XML-escaped, and `tests/windows-installer.rkt` covers code derivation, shortcut authoring, escaping, and a real `wix build` where WiX is installed. Applications installed from a release built before this change will side-by-side with the next version instead of upgrading in place; uninstall the old entry once after upgrading.
- Add the first-party Linux system adapter in `platform/linux/system`, mirroring the Windows and macOS surfaces: an abstract-socket single-instance lease with activation forwarding (peer-credential checked, so activations from other local users are rejected), desktop notifications over `org.freedesktop.Notifications` with tagged replacement ids, XDG autostart entries, Secret Service binary secrets through libsecret (compiled when present, reported as a runtime capability), POSIX fatal-signal crash hooks, and a `Capabilities()` probe that reflects what the running session actually provides. The tray contract stays deliberately absent because StatusNotifierItem hosting is compositor-dependent. The Linux integration binary self-checks the adapter (`RivetIntegration --system`), CI runs it, and the Linux host packaging no longer embeds build-machine rpaths.
- Add clean-runner desktop architecture gates. Windows ARM64 builds now force the x64-hosted MSVC toolchain (`PreferredToolArchitecture=x64`), avoiding the 32-bit HostX86 cross compiler whose address space cannot hold the WinUI precompiled header. A dedicated workflow now proves the full `doctor`/`new`/`build`/`package`/`verify` path on Windows ARM64 (`windows-11-arm`, checksum-pinned Racket 9.3 arm64 installer), macOS Intel (`macos-15-intel`), and Linux ARM64 (`ubuntu-24.04-arm`, Racket CS built from the pinned source tarball), completing build/package/verify evidence for every advertised desktop architecture; production release artifacts remain tag-driven.
- Add Kotlin typed-client generation. `raco rivet build` and `raco rivet generate` now emit a coroutine-native typed client at `.rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt` alongside the Swift/C++ clients: RPCs become `suspend` functions, Records become data classes, Enums become `enum class` values carrying their stable wire name, Events become a sealed `RivetEvent` hierarchy with typed decoding, and shared State becomes typed `get`/`set` accessors over the runtime extension functions. Identifier normalization and collision checks cover the Kotlin surface, `inspect --json` exposes `generated-clients` for every language, and CI compiles the generated client from the shared schema-matrix backend with the pinned Gradle/Kotlin toolchain.
- Add an agent-readable capability-sourcing contract. Generated projects now teach humans and coding agents how to choose among Racket packages, first-party native host APIs, safe FFI wrappers, argv-based CLI integrations, isolated sidecars, and owned implementations; `inspect --json` exposes the same decision order and release/security checklist as structured data.
- Complete the Linux release path. `raco rivet release` now runs on Linux: the verified self-contained package is packed into a deterministic ustar/gzip archive and signed with a detached Ed25519 signature (`<installer>.tar.gz.sig`, base64), configured through `RIVET_LINUX_SIGN_PRIVATE_KEY` and `RIVET_LINUX_SIGN_KEY_ID`. `raco rivet verify --production` re-derives the archive from the packaged directory, requires a byte-identical match with the released installer, and validates the signature against `RIVET_LINUX_SIGN_PUBLIC_KEY`; update manifests record the artifact as platform `linux`, installer kind `targz`. `raco rivet package --production` on Linux now points to `raco rivet release`, which owns the installer-level signing flow.

## 0.4.0

- Require Racket 9.0+ with the CS runtime (`base #:version "9.0"`); the legacy BC engine and pre-9.0 releases are no longer supported. State the floor in the landing page and getting-started guides.
- Add an agent-native project contract: generated `AGENTS.md` guidance plus `raco rivet inspect --json` for versioned project identity, native edit points, target maturity, generated-path ownership, and safe command discovery.
- Add validated application resource declarations, stable Racket-side resource lookup, Windows `.ico` compilation, and macOS `.icns` bundle metadata. Resources now participate in build, package, and verification instead of relying on platform-specific copy scripts.
- Promote Linux from a manually built GTK4 experiment to a developer preview: new projects include the Linux host, code generation emits a `rivet::linux_runtime` client, and `doctor`, `build`, `dev`, `package`, and `verify` support a statically embedded Racket CS runtime with real end-to-end CI.
- Make the portable Swift runtime available to iOS/iPadOS 16 and watchOS 9, and add a bounded, versioned `RivetDevice` request/response layer with a WatchConnectivity adapter for type-safe phone/watch companion communication.
- Add a Kotlin RVT1 codec foundation for Android, pinned Gradle tooling, and CI coverage against the same protocol vectors used by Racket, C++, and Swift.
- Add an Android coroutine client with bounded concurrent calls, Events, State helpers, backend errors, cancellation ordering, lifecycle enforcement, and deterministic Shutdown/stream cleanup.

## 0.3.0

- Added installable, searchable Scribble documentation for the core backend, system services, secure distribution APIs, and CLI workflow.
- Registered the normal installation path as `raco pkg install --auto rivet` and corrected the package license metadata to the SPDX `MIT` license identifier.
- Added an RVT1-independent `rivet/distribution` layer with SemVer channel policy, signed update manifests, Ed25519 verification, bounded downloads, SHA-256 artifact verification, staged rollout, install/restart callbacks, and rollback policy.
- Added `raco rivet release` to compose production packaging, WiX MSI or notarized DMG creation, update metadata, CycloneDX SBOM, third-party notices, and license audit output.
- Added `rivet/system` APIs for single-instance activation, notification/tray services, autostart, secure storage, atomic settings, structured logging, and provider-neutral crash hooks.
- Added first-party Windows implementations using Win32, Credential Manager, registry login startup, and Shell notifications, plus macOS implementations using AppKit, Keychain, UserNotifications, and ServiceManagement.
- Added project-level release channels, URL schemes, and file associations; macOS packaging emits the corresponding bundle metadata.
- Prepared Windows native builds and package naming for ARM64 while preserving the existing x64 path.
- Added manifest signature/tampering, version/channel, rollout, artifact-integrity, rollback, settings, logging, and system-adapter tests.
- Added an experimental GTK4/Linux embedded-host slice with real Racket CS round-trip coverage; CLI code generation, packaging, and compositor policy remain follow-up work.

## 0.2.0

Rivet 0.2 hardens the native runtime contract and release path while preserving the existing WinUI 3 / SwiftUI architecture, and completes the first-run developer experience for the first public release.

- First-run installation no longer requires cloning and linking a Rivet checkout; the documented user path installs directly from the GitHub package source.
- Added English and Chinese getting-started guides that take a new project through `doctor`, `dev`, the generated native hosts, packaging, and verification.
- The project homepage now makes **Get Started / 快速开始** the primary call to action, routes each language to its matching guide, and preserves the existing browser-language and explicit-language-override behavior.
- `raco rivet doctor` now prints actionable remediation guidance for incomplete Racket, Windows C++, and Apple developer toolchains while keeping `doctor --json` data-only for automation.
- Newly scaffolded applications include a self-guiding README with the normal edit locations, development loop, packaging commands, and English/Chinese walkthrough links.
- `raco rivet new` now prints an explicit `Next:` sequence and points developers to the generated README plus both getting-started guides.
- Deterministic embedded Racket lifecycle on macOS, including idempotent stop and restart rejection.
- Standalone Swift `RivetClient` instances now use the same one-shot lifecycle: start is reserved before the Hello read, concurrent starts are rejected, and stop/startup races cannot resurrect a stopped client.
- Typed Event schema validation and generated Swift/C++ Event APIs.
- Native identifier collision detection and language-specific codegen string escaping.
- Bounded RVT1 frame/value byte size, value nesting, total value-node count, concurrent backend and native pending requests, declared/incoming API-name size, and queued backend output.
- Racket List encoding applies the value-node budget while discovering list length instead of fully traversing oversized Lists before rejecting them; improper Lists fail explicitly without formatting the entire value.
- Typed Racket value validation applies the same List nesting and total-node budgets before encoding, avoids `list?`/`andmap` full traversals, and keeps `Any` opaque so validation itself remains bounded.
- Racket protocol encoding reports unsupported application values without formatting the object itself, so custom writers cannot amplify or replace the original codec failure.
- Synchronized request cancellation/completion ownership and non-zero UInt64 Event ID allocation; Event IDs wrap from `2^64-1` back to `1`, while terminal requests keep their pending slot until their Response/Error is admitted to the bounded output queue.
- Duplicate Request IDs and illegal inbound frame types that collide with a pending request use first-request-wins semantics, preventing a second terminal frame from consuming the original native caller's continuation; IDs become reusable after release.
- Native Windows/macOS request-ID allocators skip zero and still-pending IDs across UInt64 wraparound; cancellation is latched until its Request frame is written so Cancel cannot overtake Request on the wire.
- Native Cancel writes are linearized with pending-request ownership, so a response cannot release an ID between the final ownership check and the Cancel write and let a stale cancellation cross into a later wrapped request that reuses the same ID.
- Windows transport shutdown is serialized across concurrent `stop()` calls, blocks new Request/Cancel writes at the Shutdown boundary, and keeps the transport object alive until the native reader thread has exited before destroying its pipe handles.
- State commits defer request cancellation only across the commit-to-`$state`-Event admission window, keeping the pending slot occupied so a committed State cannot lose its native notification under output backpressure.
- Backend reader/writer supervision propagates output-port failure and stops producers instead of leaving the server blocked behind a dead writer.
- State data locking is separated from per-State update/Event ordering, so output backpressure cannot block pure Racket `state-ref` calls while concurrent setters still preserve `$state` Event order.
- Request-local handling for malformed application RPC requests and response-serialization failures, with bounded backend Error diagnostics that cannot consume terminal-response ownership before encoding succeeds.
- Diagnostic construction avoids formatting arbitrary application values or entire malformed decoded trees before final Error truncation, preventing custom writers or large values from amplifying failure reporting work.
- Request workers convert every Racket raised value, including base exceptions and non-exception values, into bounded request-local Errors so unusual application raises cannot leak pending slots or strand native callers.
- State initial values and updates are preflighted as complete `$state` Events, so serialization failures cannot partially commit backend state without notifying native clients.
- Application version, build, display-name, identifier, and Windows/macOS minimum-version metadata are centralized in `rivet.rktd` with backwards-compatible defaults.
- Shared RVT1 golden vectors consumed by Racket, C++, and Swift tests.
- Deterministic 512-value RVT1 property corpora in Racket, C++, and Swift replay the same PRNG sequence, verify canonical round-trips/truncation rejection, and assert a shared encoded-byte fingerprint.
- An opt-in Clang/libFuzzer harness exercises native RVT1 value/frame decoding under ASan and UBSan; pull requests run a bounded fuzz smoke campaign seeded from the shared golden vectors, with a reproducible per-run seed and self-contained crash/timeout/OOM payloads in CI logs.
- Strict UTF-8 validation and unknown message-type rejection across protocol implementations.
- Racket validates frame IDs as unsigned 64-bit values before writing any bytes, matching native UInt64 semantics and preventing local argument errors from leaving partial frames on the transport.
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
