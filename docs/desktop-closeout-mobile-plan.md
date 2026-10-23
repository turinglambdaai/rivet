# Desktop closeout and mobile start plan

Status: active, 2026-10-14.

This document is the durable handoff for finishing Rivet's desktop line and
starting mobile work. It records decisions, evidence, gates, and validation;
implementation details remain local to each change.

This is a temporary active plan, not permanent reference documentation. Delete
it after the gates close and move only lasting contracts into their canonical
guides or `CHANGELOG.md`.

## Decision

Rivet is a **conditional go** for mobile development.

- Windows, macOS, and Linux stop adding broad desktop surface area and enter a
  stabilization/maintenance lane.
- Mobile contract, gateway, and companion work may start while the desktop
  closeout items below are completed.
- A generated, packaged standalone mobile application flow is not called
  production-ready until the shared 1.0 contract and the applicable platform
  release gates are complete.

## Evidence at the decision point

- Rivet `v0.11.0` is the current release and `main` is clean at the release
  commit.
- The full Racket/CLI suite passes; all six portable C++ runtime tests pass;
  the Swift package tests pass when the Racket include directory is supplied
  as CI does.
- Current Rivet CI, protocol fuzzing, desktop architecture jobs, native UI
  end-to-end jobs, and the `v0.11.0` release are green.
- The closed [0.7 production milestone](https://github.com/turinglambdaai/rivet/milestone/1)
  records real Linux lifecycle evidence, first-party update installation,
  native UI end-to-end gates, and characterization-protected refactoring in
  issues [#182](https://github.com/turinglambdaai/rivet/issues/182),
  [#183](https://github.com/turinglambdaai/rivet/issues/183),
  [#184](https://github.com/turinglambdaai/rivet/issues/184), and
  [#185](https://github.com/turinglambdaai/rivet/issues/185).
- Fifteen top-level product repositories and one nested studio project consume
  Rivet. Their latest product CI runs were green at this review point.
- The latest PodLens release run is not green: the macOS x64 release build on
  Xcode 16.4 crashes in `swift-frontend` with signal 11.
- Of the fifteen top-level products, nine have no committed
  `rivet-schema.json`. Six have a baseline, but no product CI workflow runs
  `raco rivet schema check`; Keepsake and Keyward currently compare against
  stale scaffold baselines and report breaking removals.

## Desktop closeout gates

### Gate D1 — schema compatibility is operational

1. Every maintained product commits an intentionally reviewed current
   `rivet-schema.json`.
2. Every product CI runs:

   ```bash
   raco rivet schema check rivet-schema.json --json
   ```

3. `doctor`/`inspect` report a machine-readable warning when a project has no
   baseline.
4. Baseline replacement after 1.0 is treated as an explicit compatibility
   decision, not routine regeneration.

Exit evidence: all maintained product checks are green against their committed
baselines.

Progress (2026-10-14): all fifteen top-level product working trees now have a
baseline that is compatible with their current backend contract; eleven of
those repositories have uncommitted baseline additions or refreshes from this
batch. Rivet also runs the check automatically before every build when the
baseline exists, and the new gate is covered by the full Racket/CLI suite.
Explicit, focused `schema check --json` steps still need to be added to each
product workflow before this gate is closed.

### Gate D2 — release reliability is green

1. Reduce and fix or reliably work around the PodLens macOS x64 Swift compiler
   crash.
2. Complete at least one representative arm64+x64 macOS release and current
   Windows/Linux release after the fix.
3. Keep application release workflows pinned to one Rivet tag or full commit;
   avoid mixing a moving catalog/main package with a differently pinned setup
   action.

Exit evidence: representative tagged release runs and artifact verification
are green on all three desktop systems.

### Gate D3 — diagnostics describe reality

1. `inspect` reports Linux as a production target.
2. Native edit points are discovered from the application's real source tree,
   not only scaffold filenames.
3. The documented local Swift test command supplies the Racket headers used by
   CI.

Exit evidence: regression tests cover renamed/split native host sources and
the machine-readable maturity table.

Progress (2026-10-14): implemented. Linux is reported as a production
target; native edit points are discovered from real source trees; missing
schema baselines are exposed by both diagnostics; and the README Swift command
now supplies Racket headers. The full Racket/CLI suite is green.

### Gate D4 — production trust has a canary

Rivet's deterministic development release flow remains the normal PR gate.
Before declaring desktop 1.0, one protected canary must also exercise
publisher-owned production credentials: Authenticode plus timestamping on
Windows, Developer ID/notarization/stapling on macOS, and Rivet's signed Linux
installer path.

Exit evidence: credential-backed artifacts pass `raco rivet verify
--production` in their trusted release environments.

### Gate D5 — product behavior has executable evidence

1. Every maintained product commits `rivet-acceptance.rktd` and runs `raco
   rivet acceptance --json` in required Windows, macOS, and Linux jobs.
2. Requirements cover shared contract behavior, generated-client/embedded-
   backend round trips, native host builds, and at least one critical packaged
   native UI flow on every supported desktop platform.
3. UI suites use disposable profile/config/database roots and observable
   accessibility or state conditions. Fixed sleeps, process-survival-only
   smoke tests, CLI substitutes for GUI actions, and undeclared workarounds do
   not satisfy the corresponding requirement.
4. Acceptance-policy changes, native drivers, golden data, and CI gates receive
   the same protected review as public API changes.

Exit evidence: Taskly is the first product to pass the complete contract on all
three platforms; the remaining maintained products then adopt the same gate.
Rivet provides the bounded, shell-free orchestration and rejects missing
coverage, stale evidence, timeouts, or failed commands, while each product owns
its native driver and assertions.

Progress (2026-10-18): Rivet's acceptance manifest and CLI orchestration are
implemented in the current change, together with scaffold, diagnostics, tests,
and the permanent product guide. Framework CI must validate this batch before
the gate can be considered available. Taskly adoption remains pending because
its local checkout could not be fast-forwarded from the remote during this
work; no product files were edited on that unverified base.

## Non-blocking desktop improvements

These remain worthwhile but do not block mobile contract/gateway work:

- establish stable-hardware regression thresholds for startup, concurrent RPC,
  Event throughput, RSS, long-run growth, and packaged size;
- publish versioned documentation and complete missing Chinese pairs;
- expand templates only when repeated product patterns justify them.

## Mobile delivery sequence

### M0 — shared contract

Keep RVT1 v1's value-tag set closed for the first mobile gateway. `Float64`,
Map, and structured Error require explicit negotiation plus four-language
golden/property/fuzz evidence before entering a later transport contract. Use
fixed-point `Int64`, Records or sorted key/value Record lists, and typed result
Records in the meantime. Expose this boundary and the default-deny device
allowlist through `inspect --json`.

Progress (2026-10-14): implemented. `inspect --json` exposes the
closed RVT1 v1 tag set, deferred Keel types, extension/error policy, configured
device RPCs, and the default-deny gateway status. The protocol and
large-payload guides document the supported v1 representations.

### M1 — in-memory device gateway

Implement authorization, scope enforcement, request-ID mapping, cancellation,
Event/State filtering, limits, and deterministic tests without opening a
network listener.

Progress (2026-10-14): implemented in the portable Swift
`RivetDevice` target. The core owns bounded sessions and per-session request-ID
namespaces, maps remote IDs to opaque host IDs, enforces unioned scope grants,
keeps cancellation session-local, filters Events and State changes, cancels
pending work on revocation/disconnect, and applies 512 KiB, 64-request, and
8-session defaults. Focused Swift tests pass. TLS, platform persistence, RVT1
wire adaptation, discovery, and product UI intentionally remain in M2.

### M2 — Apple companion vertical slice

Use a real product such as PodLens to connect a native iOS client to the macOS
host. Cover pairing, TLS pinning, secure persistence, reconnect, revocation,
background/foreground transitions, and a minimal native UI.

Progress (2026-10-14): the framework-only pairing/authentication slice is
implemented in `RivetDevice`. It defines the byte-exact short-code
transcript, bounded pairing window/attempt state machine, injectable secure-
storage boundary, credential reconnect authentication, non-secret listable
metadata, dual-peer confirmation before credential issuance, and credential-
to-live-session revocation. `RivetDeviceAppleSecurity` now implements the
pairing store with service-scoped generic-password items, a versioned envelope,
device-local accessibility, disabled synchronization, secret-free stable
errors, and an injectable Security.framework boundary. `inspect --json` lists
the secure-storage adapter as implemented. M2b adds `RivetDeviceSession`: the
byte-exact incremental `RVD1` codec, reconnect HMAC, client/server ordering,
pairing flow, timeout policy, and the client credential-persistence gate. A
language-neutral fixture pins all nine record types, the proof, and pairing
code. M2c adds `RivetDeviceAppleTransport`: TLS 1.2+, forward-secret AEAD
cipher suites and ALPN policy, canonical X.509 SPKI extraction and SHA-256
pinning, explicit provisional-pairing trust, a 30-second connection deadline,
and an ordered Network.framework stream that cannot fall back from malformed
`RVD1` to RVT1. M2d adds a per-install P-256 identity stored in Keychain and a
disabled-by-default macOS listener. Admission is capped before transport or
session allocation, and disable, listener failure, and termination close every
accepted connection. Diagnostics now report the session preface, TLS adapter,
server identity, listener, and discovery as implemented. M2e adds
privacy-bounded Bonjour advertising only while the listener is ready. Its
deterministic, 128-byte-bounded TXT record contains only the session version, a
per-listener ephemeral ID, and the pairing-window bit; shutdown removes the
service before cancelling the listener. M2f adds the single-connection macOS
session host: it drives TLS and `RVD1`, reports pairing prompts without
auto-approval, enforces the post-TLS deadline, enters RVT1 only after server
acceptance, and performs idempotent cleanup. Product gateway binding and UI
remain pending. M2g adds the explicit iOS Bonjour browser: it accepts only the
canonical bounded advertisement, reports all candidate-field changes, removes
vanished results, and clears state on failure or cancellation without opening
a connection or granting authority. Local-network permission declarations
remain product-owned. M2h adds the framework-only iOS session client: it
accepts one explicitly selected discovery endpoint, builds a pinned reconnect
or an explicit provisional-pairing TLS context, drives `RivetDeviceSessionClient`,
surfaces the pairing code without auto-confirming it, persists each new
credential through an injected secure-storage boundary before accepting RVT1,
enforces the post-TLS deadline, and performs idempotent cleanup. Rejected
authentication closes without a pairing fallback, and discovery identifiers or
pairing hints never become credentials. No product repository or UI was
changed.

## Next implementation handoff

M3 has started. Its first slice is complete in the portable C++ runtime:
`runtime/include/rivet/device_session.hpp` implements the RVD1 v1 records,
the authentication-proof and pairing-code transcripts, and the full
server-side state machine (reconnect authentication with an
indistinguishable unknown-device challenge and constant-time comparison,
dual-confirmation pairing, injected window/attempt, secure-storage, random,
UUID, and clock boundaries, canonical scopes, stable reject codes, and the
post-TLS deadline). It is pinned by the shared `device-session-golden.txt`
vectors and deterministic codec and state-machine tests
(`rivet_device_session_test` in `runtime/`). The earlier Apple companion
layers M2a through M2h are complete and reported by diagnostics; the
remaining M2 item — product gateway binding, pairing UI, and the PodLens
vertical slice — is product-repository work coordinated with the active
Taskly-standard alignment workstream.

M3's second slice is also complete: `runtime/include/rivet/device_session_host.hpp`
drives the preface over any `rivet::Transport` with injectable clock and
thread-safe desktop decisions, pinned by deterministic pipe and multi-thread
tests (`rivet_device_session_host_test`).

M3's Android companion binding is also implemented: the Kotlin
`dev.rivet.session` package carries the RVD1 records, the client state
machine with its credential-persistence gate, a blocking runner over any
byte stream, and the canonical discovery advertisement behind a driver
interface, all pinned by the shared golden fixture. Kotlin generation now
also derives `RivetDeviceAPI` from the product's default-deny `device-rpcs`
allowlist, so an accepted Android session gets the same typed device surface
as Apple rather than the complete backend API. The Kotlin TLS stream connector
now configures TLS 1.2+ forward-secret AEAD, requires `rivet-device/1`
ALPN, pins the SHA-256 of the leaf DER SubjectPublicKeyInfo on reconnect,
and permits provisional trust only for an explicitly selected pairing
attempt. A single 30-second connect/handshake budget closes failures without
exposing application streams. It is pinned by JVM policy/unit tests, not
Android-device evidence. The remaining M3 work includes the Android NSD
platform adapter, product UI/storage, and real-device acceptance.
The independently reviewed `DeviceCompanionSession` bridge binds one
explicitly selected TLS endpoint and observed fingerprint to the RVD1
session client, surfaces explicit pairing approval, hands the accepted
stream to the product's RVT1 client only after the persistence gate, and
closes failed or cancelled transport attempts. Kotlin/JVM tests cover
wrong pins, no reconnect-to-pairing fallback, accepted stream ownership,
and cancellation during an in-flight TLS dial. The accepted RVT1 client now
applies the payload and pending-request budgets negotiated by its RVD1
session: oversized outgoing RPCs are rejected before any frame is emitted,
oversized incoming frames fail closed, and malformed acceptance budgets are
rejected during session establishment, all pinned by deterministic JVM
tests. The save-before-accept gate
now has a product-shaped Android persistence adapter: one Keystore AES key
per application ID seals each credential/fingerprint record into a versioned
AES-GCM envelope whose additional authenticated data binds it to the product
and paired device, SharedPreferences holds only that ciphertext, a duplicate
or unknown pairing ID never rotates silently, and a missing or corrupted
Keystore key fails closed into one stable error taxonomy instead of offering
a re-pairing path. The adapter is compile- and envelope-tested on the JVM;
Keystore-backed behavior itself requires device evidence. The Android
`NsdManager` driver, product credential integration, and device-to-device
evidence remain separate unfinished M3 tasks.

M3's Windows transport slice is also implemented: a CNG-persisted P-256
self-signed identity with deletion-based rotation, an SChannel TLS server
requiring the `rivet-device/1` ALPN and failing closed on renegotiation, a
bounded listener, and a DNS-SD publication of the shared canonical
advertisement, all behind `rivet::windows::DeviceSessionService`, which
feeds accepted TLS transports to the portable `rivet::DeviceSessionHost`.
The portable X.509 SubjectPublicKeyInfo extractor keeps companion pins
byte-identical across platforms. This code compiles only under the
Windows SDK, so it has not run on real hardware yet: acceptance requires a
Windows machine to verify identity creation, listener start, DNS-SD
visibility (`dns-sd -B _rivet-device._tcp` from another host), and an iOS
provisional-pairing handshake. After that, supply Android NSD resolution,
connect the Kotlin TLS stream and `SessionClientRunner`, and exercise the
generated `RivetDeviceAPI` using the same golden fixture. Read `docs/network-device-channel.md` for the
wire and timing contract and reuse the language-neutral fixtures; do not
reinterpret the preface per platform.

Android native NSD discovery and resolution now have a separate
`platform/android/android-nsd` Android SDK 35 compile target. The
`AndroidNsdDriver` implements both portable discovery and selected-resolution
interfaces, canonicalizes resolved TXT attributes, bounds candidates and
suppresses stale callbacks. Android-specific compilation is checked in the
Kotlin CI job; canonical TXT mapping has JVM tests. The product still owns
local-network permission prompts, foreground/multicast lifecycle, secure
credential storage and mobile UI; physical-device network pairing remains
unverified.
The portable `SelectedDeviceCompanionCoordinator` now bridges that live NSD
selection to exactly one authenticated RVD1 attempt on an injected worker,
with fail-closed cancellation and explicit pairing-window policy. It still
requires product-owned credential storage, UI approval and real-device proof.

### M3 — second desktop host and Android client

Add the Windows gateway against the same iOS client, then bind Android
discovery/TLS streams to the existing Kotlin runtime and generated device API.

The Apple post-RVD1 RVT1 path now has a bounded client and scoped gateway
server, a backend adapter for the existing local RPC client, cancellation
forwarding, and per-device event/state-change filtering. Generated Swift APIs
support a shared RPC interface with compatibility for the released in-process
SwiftPM runtime, so network and in-process clients share typed methods.
Product host wiring, scope selection, event fan-out, and real-device
acceptance remain open gates.

Apple companion coverage extends to iOS and iPadOS through the shared
iOS transport, and watchOS through a separate WatchConnectivity request
relay to its paired iPhone. The relay requires activated/reachable
WCSession state, non-empty bounded messages and replies, and an
iPhone-owned route allowlist and authenticated desktop session. CI now
includes iOS/watchOS device and simulator framework compilations and
deterministic Swift relay tests. Neither standalone iPad/watch
applications nor real-device pairing, background connectivity,
signing and package acceptance are implied by these framework gates.

The shared Apple companion framework now has a reusable iOS/iPadOS
orchestrator that checks a selected Bonjour candidate is still current,
requires explicit pairing intent or a stored pinned pairing, routes pairing
codes through an async event stream, persists the new credential before RVT1
handoff, and updates granted-scope metadata before the product callback.
A reusable `RivetDeviceAppleCompanionUI` SwiftUI view/model now provides
nearby discovery, pair/reconnect actions, explicit pairing-code approval,
saved-pairing removal and session status. The watchOS relay also exposes
reachability changes and a `RivetWatchCompanionView` shell for one
product-supplied typed action. The host pairing-window ID, post-RVD1
application handler, and watch action remain product inputs; no generated
app, signing, or physical-device acceptance is implied.

### M4 — standalone mobile hosts

Only after the shared contract is stable, pursue Android JNI/portable Racket +
Compose and the corresponding Apple embedded-runtime application flow. Each
requires generated projects, lifecycle/process-death tests, signing, packaging,
and device/emulator round trips before developer-preview status. The Apple
flow must cross-compile bundled application modules for the iOS target, pass a
Release build and physical-device run without JIT or executable-memory runtime
exceptions, and contain no post-review code-download path before App Store
submission is considered supported.

## Completion cleanup

This file is deleted after the desktop gates and the selected mobile-start
milestone close. Before deletion, move durable protocol/security decisions to
`protocol.md`, `device-communication.md`, or `network-device-channel.md`; move
developer procedures to their platform guide; and summarize delivered changes
in `CHANGELOG.md`. Do not retain completed checklists, dated progress snapshots,
or this handoff narrative as parallel reference documentation.

## Handoff rule

An agent resuming this work should read this document, `AGENTS.md`, the nearest
implementation and tests, `docs/network-device-channel.md`, the Android section
of `docs/architecture.md`, and `platform/android`. Update this plan only when a
gate, decision, or evidence item changes; do not turn it into a commit-by-commit
diary.

The committed framework batch containing this plan changes Rivet diagnostics,
the automatic build schema gate, the device gateway/pairing core, their tests,
and related documentation. Separate product-repository edits are
limited to adding missing baselines in Autarx, FlashPilot, Fulcrum, gPTP Studio,
Payback, PodLens, RegexMate, Taskly, and Threadly, plus refreshing the stale
Keepsake and Keyward baselines. Preserve all other dirty files in those product
repositories; they belong to separate user work.

A separate active workstream is aligning all Rivet products to Taskly's upgrade
and experience standard. This framework workstream must not make further
product UI, release-workflow, or generated-client edits while that alignment is
in progress. Coordinate the remaining explicit product CI schema steps with
that workstream instead of editing the same workflows concurrently.
