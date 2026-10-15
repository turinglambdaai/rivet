# Changelog

## Unreleased

- Add the portable C++ device-session host driver. Over any
  `rivet::Transport`, `rivet::DeviceSessionHost` runs the RVD1 preface for
  one accepted desktop connection, enforces the post-TLS deadline, surfaces
  pairing codes without auto-approving, accepts the desktop user's
  confirm/reject decision from another thread with transport writes
  serialized against the run loop, waits on the pairing-window clock, and
  hands the accepted stream to an application handler only after
  acceptance. Deterministic pipe, clock, and multi-thread tests pin the
  reconnect, pairing, rejection, timeout, cancellation, and malformed-preface
  behavior; the Windows and Linux gateways become thin transports over it.
- Add the portable C++ device-session preface for the Windows and Linux
  gateways. `rivet/device_session.hpp` implements the RVD1 v1 records, the
  HMAC authentication proof and six-digit pairing-code transcripts, and the
  server-side state machine: reconnect authentication with an
  indistinguishable unknown-device challenge and constant-time proof
  comparison, dual-confirmation pairing over injected window/attempt and
  secure-storage boundaries, canonical scope enforcement, stable reject
  codes, and the post-TLS deadline. The shared
  `device-session-golden.txt` vectors plus deterministic codec, transcript,
  and state-machine tests pin the contract; TLS transport, listeners, and
  discovery remain platform work.
- Move the test suite under the `rivet` collection (`rivet/tests/`). A
  top-level `tests/` directory inside a multi-collection package publishes a
  generic `tests` collection that cannot coexist with any other package
  doing the same, which the package catalog reports as a conflict. The suite
  now follows the family layout used by the other Rivet libraries, and
  `raco test rivet/tests/` is the documented entry point.
- Keep the package build farm green on hosts without desktop conveniences.
  Console executables are now resolved from the running installation's bin
  directory before PATH, so the build, launch-smoke, and AppImage process
  tests run on build farms that invoke `bin/racket` by a relative path.
  Digest- and signing-dependent tests skip with a notice where the pinned
  libcrypto factory is unavailable, the manifest composer skips without an
  Ed25519 provider instead of raising, and CI-wiring checks tolerate packaged
  copies that omit dot-directories.
- Add the framework-only Apple session client for iOS companions.
  `RivetDeviceAppleSessionClient` connects one explicitly selected endpoint
  through a pinned reconnect or an explicit provisional-pairing TLS context,
  drives the `RVD1` session client state machine, surfaces the pairing code
  without auto-confirming it, persists each new credential through an injected
  secure-storage boundary before accepting RVT1, enforces the post-TLS
  deadline, and closes without a pairing fallback when authentication is
  rejected. Connection, session-client, persistence, and deadline boundaries
  are injectable for deterministic reconnect, pairing, persistence-failure,
  timeout, cancellation, and malformed-preface tests; connection policy,
  background lifecycle, and permission strings stay product-owned.
- Add the framework-only Apple Bonjour browser for iOS companions. Browsing is
  explicitly started and stopped, accepts only the canonical bounded Rivet TXT
  record, bounds candidates and pending events, reports add/change/remove
  lifecycle events, and clears candidates on failure or cancellation.
  Discovery remains unauthenticated and never opens a connection; local-network
  usage strings and Bonjour declarations stay owned by the consuming
  application.
- Connect accepted macOS device transports to a fresh `RivetDeviceSessionServer`
  through `RivetDeviceAppleSessionHost`. The host enforces post-TLS deadlines,
  reports pairing codes without auto-approval, switches to RVT1 only after
  authenticated acceptance, and performs idempotent disconnect cleanup.
- Repair generated-project package smoke tests after the schema compatibility
  gate became automatic. Workflows that intentionally replace the scaffold
  backend now explicitly regenerate and verify their reviewed schema baseline
  before build/package checks, preserving the gate instead of bypassing it.
- Add the first Apple companion-session security layers. Service-scoped,
  device-local Keychain storage now persists pairing credentials on macOS and
  iOS, while `RivetDeviceSession` supplies the bounded `RVD1` preface codec,
  HMAC reconnect authentication, dual-confirmation pairing state machines, and
  a credential-persistence gate. Language-neutral golden vectors and
  deterministic malformed-input, ordering, timeout, and authentication tests
  pin the contract before Network.framework integration.
- Add `RivetDeviceAppleTransport` for the next Apple companion layer. It
  configures Network.framework for TLS 1.2+, forward-secret AEAD suites, and
  the `rivet-device/1` ALPN,
  authenticates either an exact server SPKI SHA-256 pin or an explicit
  provisional-pairing identity, extracts canonical SPKI DER from X.509, bounds
  connection setup to 30 seconds, and preserves the one-way `RVD1` to RVT1
  stream transition without exposing a listener or discovery service.
- Add the disabled-by-default macOS device listener and per-install P-256 TLS
  identity lifecycle. Private keys and their self-signed certificates stay in
  the application Keychain namespace; explicit rotation invalidates the public
  pin. Listener admission is capped before transport/session allocation, and
  disable, failure, and termination close every accepted connection. Product
  enablement remains a separate future step.
- Add privacy-bounded Bonjour advertising to the macOS device listener. The
  `_rivet-device._tcp` service exists only while the listener is ready, carries
  a deterministic 128-byte-bounded TXT record with the session version, a
  per-listener ephemeral identifier, and the pairing-window bit, and is removed
  before shutdown. No API names, account/device identifiers, filenames, or user
  content enter discovery; iOS browsing and product UI remain separate work.

## 0.11.0

- Drop the IsolatedDeinit experimental feature from the released SwiftPM
  packages. Released Xcode toolchains reject experimental features outright,
  so package consumers could not compile RivetSystem away from trunk
  compilers; the clipboard change-observation teardown now uses a plain
  deinit over a nonisolated stored Timer, which every toolchain accepts.
- Open the Windows taskboard reference window at a size that keeps every
  layout region usable. At the WinUI default window size the timing-chart
  row squeezed the task list into a virtualizing sliver whose row
  containers never realized — invisible in the UI and to UI Automation —
  and the native-UI end-to-end wait timed out waiting for the RPC-created
  row even though the RPC itself had succeeded.
- Make packaging a clean native provenance boundary (#235). Windows package
  builds use MSBuild `Rebuild`, macOS recreates the SwiftPM scratch tree, and
  Linux already recreates its CMake tree; incremental caches can no longer
  produce a valid-looking distributable from older native objects.
- Finish the shared host-side update story on Windows and Linux (#237) without
  duplicating the engine's security-critical Ed25519/parser/downloader stack.
  Signed release feeds now carry portable ZIP plus MSI on Windows and portable
  ZIP plus AppImage on Linux; `make-updater` selects explicit `portable`, `msi`,
  or `appimage` install shapes. The released Windows library adds a bounded,
  failure-reporting `msiexec` quit/install/relaunch handoff with stale-attempt
  cleanup and lease release, while the Linux library adds install-shape and
  post-commit AppImage relaunch helpers around the existing atomic adapter.
- Complete released-package consumption (#238). Generated macOS hosts resolve
  Rivet from its tagged root SwiftPM package rather than a checkout path;
  Windows and Linux hosts link the released package's platform targets; the
  old Linux source fragment is now explicitly private to `rivet::platform`.
  Both Windows static-library projects now declare ARM64 configurations.
- Preserve the clean release output contract from #236: the unpacked staging
  bundle is removed after installers, portable archives, manifests, SBOM, and
  notices are produced. The canonical Linux source manifest and anti-drift
  guard from #234 remain internal implementation details of the linkable
  package rather than an invitation for downstream source compilation.
- Fix the linkable Windows and Linux chart packages to carry the shared
  chart batch codec/model implementation. The pre-release embedded roundtrip
  caught the prior compile-green/link-red package before 0.11.0 shipped.
- Isolate NuGet restore state for the sibling Windows host and chart library
  projects. Both libraries now participate in the transitive restore graph,
  so clean downstream builds receive the WinUI/C++/WinRT projection headers;
  canonical directory-valued MSBuild output paths also remove the old MSB8004
  warning from referenced-library builds.
- Make the Windows host template's CRT selection explicit and consistent.
  Self-contained packages use MT/MTd while development builds use MD/MDd,
  and the selected mode is applied to the executable and forwarded to every
  released static library, preventing clean-package LNK2038 failures.
- Make the Windows chart library independent of downstream precompiled
  headers by declaring its C++/WinRT dependencies directly, avoiding Win32
  macro leakage, and using the correct `Windows.UI.Color` type.
- Update the Windows reference consumer to use the released `rivet::win_ui`
  namespace and the chart control's public default-construction contract.
- Keep post-release verification compatible with the clean output contract.
  When the unpacked staging package is gone, `raco rivet verify` now validates
  the portable ZIP through an isolated temporary extraction with strict root
  layout checks and unconditional cleanup.

## 0.10.0

- Host platforms ship as linkable packages — downstream products never
  compile Rivet sources into their own build lists (constraint recorded
  in #238). Linux gains a `rivet::platform` static library under
  `platform/linux/` that the host template, the integration binary, and
  the taskboard example `add_subdirectory()` and link; the scaffold's
  generated CMake does the same. Windows gains
  `platform/windows/rivet-host.vcxproj` (static library) which the host
  template references via `ProjectReference`, with hybrid-CRT hosts
  forwarding their `RuntimeLibrary` choice through
  `RivetRuntimeLibrary`. A root `Package.swift` exposes the macOS
  products as a tag-resolvable SwiftPM package
  (`.package(url: …, from: "0.10.0")`) beside the in-repo path package.
  The WinUI HWND bridge moves to `winui_window.hpp` so the Windows
  library compiles without Windows App SDK include paths.
## 0.9.0

- Close the last below-floor commercial capability gap with first-party
  native file dialogs on every desktop platform. Windows uses Common Item
  Dialogs, macOS uses asynchronous AppKit panels, and Linux uses GTK4 native
  choosers with portal delegation. The adapters cover open, save, folder
  selection, extension filters, cancellation, and open-file multi-selection
  without adding file-picker traffic to RVT1.

- Make Linux a first-class product target everywhere users discover Rivet:
  the English and Chinese READMEs now include its badge, requirements,
  positioning, and comparison stack; the bilingual landing page includes
  GTK4 in both the native-UI feature card and comparison table; and the stale
  unsupported-host remediation no longer claims only Windows and macOS can
  build. Documentation tests pin all three targets to prevent this class of
  omission from returning.
- Fix source-package smoke tests under `set -o pipefail`. Archive entries are
  now read once and checked from a file, so `grep -q` cannot close a repeated
  `unzip` pipeline early and turn a successful match into spurious exit 141.
  Source releases also explicitly omit native build/output trees (the Racket
  packager does not read `.gitignore`), and the isolated install overrides any
  maintainer-machine installation-scope link instead of producing a false
  “already installed” result.

- Add first-party plain-text clipboard read/write/change observation across
  every desktop adapter. macOS uses `NSPasteboard` with main-run-loop
  `changeCount` polling, Windows uses `CF_UNICODETEXT` plus a message-only
  clipboard owner and `WM_CLIPBOARDUPDATE`, and Linux uses GTK4/GDK with
  asynchronous reads suitable for Wayland ownership transfers. Native
  observation stays on the platform UI thread and outside RVT1.
- Complete cross-platform global shortcuts. Linux already binds through the
  XDG portal; macOS gains `RivetGlobalShortcuts` (Carbon
  `RegisterEventHotKey`, main-thread event loop, explicit duplicate-trigger
  refusal — RegisterHotKey provides it on Windows, Carbon does not) and
  Windows gains `rivet::system::GlobalShortcuts` (`RegisterHotKey` on a
  message-only window with `WM_HOTKEY` dispatch). The three adapters share
  one activation-callback shape (shortcut id, millisecond timestamp,
  portal-only activation token) and direct-registration platforms share a
  case-insensitive trigger grammar; ANSI virtual-key codes map through
  their Carbon constants because the codes follow the physical QWERTY
  layout, not the alphabet. macOS parse and lifecycle tests are in the
  Swift suite; the Windows adapter is compile-gated by the WinUI CI host
  build.
- Add `docs/commercial-parity.md`: the honest scorecard against the Tauri 2
  and Electron feature floors (above / at / below / roadmap per
  capability), with rules of engagement — a product hand-rolling the same
  capability twice is a library gap, below-floor rows outrank new surface
  area, and the docs suite keeps the scorecard's tracked capability rows
  (global shortcuts, clipboard, native file dialogs, mobile hosts) from
  silently disappearing.
- Close the scribble coverage gap: the RVT1 framing and value-codec surface
  (`rivet/protocol` — frames, message-type constants, transport limits,
  read/write/encode/decode), application resources (`rivet/resources`),
  the diagnostic sink parameter, `install-crash-hook!`, the version
  predicates, the Ed25519 key/digest/base64 primitives, canonical manifest
  payload helpers, `verify-update-artifact!`, `make-install-plan`,
  `current-install-kind`, and the missing `updater?` predicate now have
  manual entries. Every public export is covered and the rendered manual
  carries no undefined-tag warnings.
- Documentation drift now fails CI instead of rotting silently. The docs
  suite derives the current release version from `info.rkt` and rejects a
  `docs/ci*.md` guide pinning any other tag, and it checks scribble
  coverage in both directions: a public export without a manual mention
  fails, and a manual entry for a binding that is no longer exported fails
  (defstruct* forms synthesize their constructor, predicate, structure-type
  binding, and accessors, mirroring the rendered output).

## 0.8.1

- Add the macOS `RivetUpdate` Swift module: a shared host-side update client
  for installed `.app` bundles, so applications stop hand-rolling the same
  security-critical download/verify/swap flow per product. It verifies the
  family's signed manifest wrapper (Ed25519 over exact payload bytes before
  any JSON parsing), downloads through a delegate-driven session whose
  completion callbacks are definitive — byte-iterating `AsyncBytes` can park
  its continuation forever on a lost end-of-stream flag — enforces signed
  size during transfer and on the delivered file, confirms the unpacked
  bundle version, and swaps atomically with rollback and relaunch.
  Configuration fails closed (HTTPS-only feeds outside loopback drills,
  raw-32-byte keys, bare `*.app` bundle names), task cancellation always
  resumes promptly, and progress stays within 0…100. The swap handoff owns
  two traps verified on a real stalled OTA: the spawned script keeps the
  work directory (`cleanupStaleWorkDirectories` sweeps crashed attempts at
  startup), and a presented sheet vetoes `terminate` silently — the module
  ends every sheet, terminates, and stops the run loop if the quit was
  deferred.

## 0.8.0

- Reject self-contradictory signed update manifests before publication or
  client acceptance: artifact sets must be non-empty and positive-size,
  minimum/previous versions must precede the release, and artifact
  platform/architecture/installer identities must be unique. Signed wrappers
  and payloads also reject trailing JSON values and fields outside their
  versioned schemas.

- Add an opaque managed updater for the check/select/download lifecycle shared
  by downstream applications. It copies mutable configuration inputs and
  provides deeply immutable, synchronized JSON-safe state,
  one background worker, progress, explicit cancellation, monotonic manifest,
  stall, and total deadlines, deterministic destinations, and terminal cleanup
  while leaving installation and restart with the native host.
- `download-update` reports download progress: an optional `#:on-progress`
  callback receives cumulative bytes from zero through the final downloaded
  size. Intermediate reports are throttled to about one per percent of the
  signed artifact size by default, with an optional byte cadence for activity
  watchdogs. In-app updaters can drive progress bars without copying Rivet's
  bounded, redirect-aware downloader. Interrupted or cancelled downloads
  remove their partial file as reliably as ordinary failures.

- Authenticate signed update-manifest payload bytes before parsing their JSON.
  Malformed, unauthenticated payloads now fail at the Ed25519 boundary instead
  of entering semantic validation and contradicting the documented trust
  order. `read-signed-manifest` remains an explicitly unauthenticated
  inspection API; update clients use `verify-signed-manifest`.

- Serialize portable update execution and recovery with an installation-scoped
  in-process semaphore plus a target-derived operating-system file lock, even
  when callers configure different backup paths. A competing updater now fails
  before it can remove or rename shared staging, backup, marker, or journal
  state; the persistent empty lock file is not a crash marker. The prepared
  installation handle is opaque so callers cannot forge its lock identity.

- Make `settings-store` an opaque synchronized handle. The pre-1.0 API no
  longer exports its constructor, path/lock/data fields, or mutation setters,
  which allowed callers to bypass atomic persistence and replace the store's
  lock. Transactions refresh under shared in-process and operating-system
  locks to prevent stale handles from losing updates; stored JSON trees and
  snapshots are deeply immutable. Use `make-settings-store` and the existing
  controlled operations; `settings-store?` remains public.
- Add a Windows `rivet::system::TrayController` that owns tray window
  subclassing, localized native menu presentation, command dispatch, and
  automatic `TaskbarCreated` recovery. The reference Taskboard now exercises
  the blessed tray-resident host pattern instead of leaving every application
  to rediscover `TrackPopupMenu`'s foreground-window requirement.
- The Windows tray icon (`rivet::system::TrayIcon`) can update its tooltip
  (`SetTooltip`) and re-register itself after an Explorer restart
  (`Readd`, called from the host's `TaskbarCreated` broadcast handler) —
  state-aware tray apps no longer re-allocate the icon to relabel it and no
  longer lose it the first time the shell restarts. `TrayIcon` owns an icon
  copy so recovery does not impose a new lifetime requirement on callers.
- Document one reproducible downstream install contract: pin Rivet's Git
  package source and `setup-embed-racket` action to the same revision, and
  install the package only after the minimal embeddable runtime is active.
- Add Wayland-safe Linux global shortcuts through the XDG Desktop Portal,
  including asynchronous consent/binding results, compositor activation tokens,
  runtime capability discovery, and a hermetic mock-portal integration test.
  Rivet deliberately provides no X11 `XGrabKey` fallback.

- Bound and retry Ubuntu runner package-manager operations so a stalled mirror
  cannot consume an entire desktop validation job without a useful failure.
- Removed the misleading `rivet-type` runtime descriptors from the pre-1.0
  public surface. Schema type identifiers are declaration grammar, while Keel
  is the canonical runtime-inspection model.
- Added an exact public-export contract and a Racket 9.0 CI lane so accidental
  API drift and minimum-version regressions fail before merge.

- Make Keel's validated `app-schema` the canonical in-memory input to Swift,
  C++, and Kotlin client generation. Rivet now keeps only a fail-closed
  Keel-to-RVT1 type adapter instead of reconstructing a parallel codegen schema
  model, while preserving generated source and schema snapshot compatibility.
- Synchronize the English and Chinese CI guide with the pinned Ubuntu 24.04
  runner and remove a stale comment about the now-opaque State descriptor.

## 0.7.0

- Stage Racket's bundled foreign runtime libraries (`libeay32.dll`,
  `ssleay32.dll`, `libgmp-10.dll`) beside the Windows host executable.
  Embedded backends resolve these by bare DLL name through the FFI —
  OpenSSL for `racket/openssl` and the libcrypto factory (TLS and update/
  license verification), GMP for `gmp-lib` and `math` — and a package that
  only carried the Racket CS DLL died at startup or first crypto use with
  `ffi-lib: could not load foreign library`.
- Pin the MSI's Add/Remove Programs tile to the configured Windows icon
  (`ARPPRODUCTICON`); shortcuts and the executable already inherited it
  from the compiled resource.
- Adopt Keel as Rivet's transport-neutral schema contract. The new
  `backend-schema->app-schema` and `current-backend-app-schema` adapters project
  RPC, Event, State, Record, and Enum declarations into a validated,
  deterministic Keel `app-schema` while RVT1 framing and native renderers stay
  Rivet-owned. Align schema placement rules with Keel: `Void` is valid only as
  a direct RPC result, not inside parameters, containers, Records, Events, or
  States.
- Split the Linux system adapter into focused single-instance, notification,
  tray, autostart, secure-storage, and crash/shutdown implementation units,
  with one private XDG/D-Bus support core and no public API change.
- Make AppImage the signed Linux update payload when that format is enabled,
  emit its SHA-256 sidecar, and add install-kind-aware update selection so
  AppImage, portable, and package-manager installations cannot cross streams.
- Graduate the Linux package-manager lifecycle gates from a single install to
  two-version deb/rpm transactions: corrupt upgrades preserve the working
  install, normal upgrades replace both metadata and payload, Debian rejects
  implicit downgrade while Fedora verifies explicit local-RPM rollback and
  re-upgrade, and uninstall remains complete under native Wayland.
- Make embedded diagnostics opt-in across Racket, C++, and Swift. GUI hosts no
  longer write to standard error by default, preventing Windows applications
  from allocating a black console window on their first diagnostic; explicit
  structured-log and stderr sinks remain supported.
- Replace the accidental public backend registry structs and mutable State
  cell accessors with an opaque `state?` handle and a single immutable
  `backend-schema` reflection snapshot. Pre-1.0 tooling that used
  `registered-*` or `*-info-*` should read the corresponding schema entry;
  applications should use `state-ref` and `state-set!`.
- Add real Linux installer lifecycle gates: build x64 rpm/AppImage artifacts,
  install and launch the rpm on Fedora 44 under native Wayland, launch the
  AppImage outside the build tree on Ubuntu 24.04, uninstall the rpm, and
  retain package/compositor/application diagnostics as CI artifacts.
- Add first-party portable update installation for Windows, macOS, and Linux:
  verified ZIP/AppImage payloads are staged, platform-signature checked,
  atomically replaced, health-gated, durably committed, and recoverable after
  interruption. Native MSI/MSIX/DMG/PKG/deb/rpm artifacts remain explicitly
  owned by their system installer or package manager.
- Adopt a Wayland-first Linux display policy, document X11/XWayland as
  best-effort GTK compatibility, and launch the packaged GTK4 host through a
  headless native Wayland compositor in CI.

## 0.6.1

- Fix the 0.6.0 family-release path: `manifest-compose --output` no longer
  treats the destination as another input, every release leg's Ed25519
  signature and key ID are verified before aggregation, and the command is
  listed in `raco rivet help`.
- Make portable update archives honor the documented
  `<name>-<version>-<os>-<arch>.zip` convention and point per-platform update
  manifests at those archives instead of the separately published installer.
- Carry `linux-binary-name` through deb/rpm desktop entries, AppImage staging
  and `AppRun`, dependency collection, and production verification. Native
  Linux formats now work with product executables instead of assuming
  `RivetHost`.
- Make AppImage command capture check exit status and collect stderr without
  the serial-pipe deadlock risk of the previous `process*` implementation.
- Keep the source-package release smoke test self-contained by validating its
  JSON contract with Racket instead of an incidental Python dependency.
- Refresh the English and Chinese Linux capability summaries to reflect the
  shipped native installers and StatusNotifierItem tray implementation.

## 0.6.0

- Add `raco rivet manifest-compose`: folds the per-platform signed
  update manifests from a multi-platform release into ONE family-wide
  signed manifest (one artifact per platform/architecture, identity
  fields verified identical across legs, Ed25519 wrapper unchanged) —
  replacing the per-product hand-rolled merge scripts. Fixes #175.
- `raco rivet release` now emits a portable zip beside every installer
  (family naming, sha256 alongside) — the family update feed and
  locked-down machines consume it directly.
- Document the multi-platform release matrix convention (runner labels,
  per-arch Racket installs, family artifact naming, the compose step) in
  docs/release-and-updates.md.
- Windows and macOS hosts now shut the embedded backend down orderly on
  session end. The Windows system adapter gains InstallShutdownHook
  (SetConsoleCtrlHandler: CTRL_C/CLOSE/LOGOFF/SHUTDOWN) and the scaffold
  wires it plus the window-close path to a thread-safe backend stop; the
  macOS scaffold installs an NSApplicationDelegate whose
  applicationShouldTerminate stops the backend for Cmd-Q, logout, and OS
  shutdown. Mirrors the Linux InstallShutdownHook shipped by #128 and
  wired into the scaffold by #168. Fixes #120.
- Document the large-payload conventions (docs/large-payloads.md): cursor
  pagination with fail-closed limit caps for report-shaped RPCs, stable-id
  tree nodes with windowed children for virtualized trees, and typed
  progress records instead of stringly-typed events, including the current
  scope of cancellation. Fixes #133; covers the convention layer of #131
  and #132.
- Add rivet/testing: an ephemeral-port HTTP listener (racket/tcp cannot
  report the bound port; this probes once and returns both the port and
  the listener) plus a sequential request-capture fake server with
  loopback close-race handling. Test suites only; never enters an embedded
  payload. Fixes #98.

- Cut ~100 MB (48%) from Windows release payloads. The packaged app no
  longer ships MSBuild debug symbols (*.pdb, 60+ MB) or the ONNX and
  DirectML inference runtimes (~40 MB) that Windows App SDK
  self-contained deployment drags beside every app; Rivet hosts link no
  Windows AI APIs, and the exclusion is pinned by an explicit list plus
  a launch smoke on every package. Fixes #144.

- Windows hosts now compile a VERSIONINFO resource into the exe. The
  generated app-icon.rc always carries the project identity
  (ProductName/FileDescription/Company from rivet.rktd, versions as
  version.build) so Explorer, Task Manager, and installer UX show the
  product instead of a bare framework binary; the icon line still rides
  along when windows-icon is declared. The WiX missing-tool hint now
  points at dotnet tool install with a 5.x pin (WiX 7 aborts on the
  Open Source Maintenance Fee EULA). Closes the identity half of #166.

- Linux hosts now terminate on SIGTERM/SIGINT. The host scaffold and the
  Taskboard example install Rivet's shutdown hook so a termination signal
  runs the same orderly backend shutdown as the GTK shutdown signal and
  then exits; previously the embedded backend died on the signal while the
  GTK process stayed up, leaving a window that could not search or run
  anything (observed on Fulcrum 0.4.1: `kill` left a half-dead app that
  only SIGKILL would remove).
- Honor `linux-binary-name` in `rivet.rktd`: the Linux build stage, package
  staging, verification, and launch smoke now use the configured executable
  name instead of the hardcoded scaffold name `RivetHost` (default
  unchanged). Apps ship as their product name — `fulcrum`, not a generic
  host binary — matching what the docs and desktop entries already say.
  Partially addresses #169.
- Build native Linux system installers from `raco rivet release`: a deb
  (dpkg-deb, unprivileged, installs under /opt with a desktop entry and
  pixmaps icon), an rpm (rpmbuild BUILDROOT, no distro-specific macros), and
  an AppImage carrying the GTK4 dependency closure with compiled GSettings
  schemas and pixbuf loaders so one file runs on older distributions. The
  set is selectable via `linux-formats`; the signed tar.gz update payload
  remains unchanged. Production verification validates each format with
  its own tooling (dpkg-deb -x, rpm -qpl, --appimage-extract), and the
  Linux CI matrix smoke-builds and verifies all three end to end.

- Add a supported WinUI 3-to-`HWND` bridge. Generated Windows hosts expose
  `WindowHandle()` through the first-party system adapter, centralizing the
  Windows App SDK `IWindowNative` ABI and removing the need for title-based
  `FindWindowW` workarounds.
- Load `raco rivet` subcommand modules lazily. A stale bytecode cache in a
  linked checkout now fails inside the command entry point, which detects the
  `instantiate-linklet` mismatch and prints the working remedy (clear
  `compiled/` + `raco setup rivet`) instead of crashing raco dispatch with a
  raw linklet dump. Partially addresses #145.
- Align Swift and Kotlin state accessors with the generated RPC naming: they
  are now `get_<state>`/`set_<state>` instead of a camelCase prefix glued to a
  snake body (`getRepo_root`). This is a breaking rename for Swift/Kotlin call
  sites; C++ was already snake_case and is unchanged.

- Scope generated Swift Records and Enums under `RivetTypes`. Common domain
  names such as `Task` and `Result` no longer shadow Swift concurrency or
  standard-library types across the application module; native Swift call
  sites now use `RivetTypes.<SchemaName>`.

- Add a reusable checksum-pinned Linux embeddable-Racket setup action and a
  bilingual native-host CI guide. The guide requires WinUI, SwiftUI/AppKit,
  and GTK4 hosts to compile before release on matching runner image classes,
  and the resource guide now shows the verified cross-platform `app/` layout
  for shared product data.- Add a first-party plain-GTK4 theme resolver. Linux hosts now reconcile the
  desktop color-scheme signal with the effective `gtk-theme-name` variant
  before creating widgets, preventing application CSS and native controls from
  landing on opposite light/dark palettes; pure resolution cases run in CI.
- Add `raco rivet release --without-updates` for products that deliberately
  ship without an online update channel. The release still produces and
  verifies its platform installer, SBOM, and third-party notices while update
  credentials and the signed channel manifest are omitted explicitly.

- Follow HTTP redirections (10 hops) in `fetch-update-manifest` and
  `download-update`. GitHub release assets — the dominant update origin —
  answer with a 302 to their CDN, so an updater pointing at
  `releases/latest/download/…` previously verified an empty body and every
  check failed.
- Ensure isolated RPCs sent after an idle interval run immediately in embedded
  Racket CS hosts instead of waiting for a later frame to wake request dispatch.
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
