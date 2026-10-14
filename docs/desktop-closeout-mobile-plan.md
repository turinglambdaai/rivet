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
`RVD1` to RVT1. Diagnostics now report the session preface and TLS adapter as
implemented while listener, identity provisioning, discovery, and product UI
remain pending. No product repository or UI was changed.

## Next implementation handoff

M2a through M2c are complete. Deterministic tests cover secure-store lifecycle and
failure mapping; all session record types and cryptographic vectors;
fragmented/coalesced reads; size, shape, ordering, duplicate, and timeout
failures; indistinguishable reconnect failures; dual-confirmation pairing; and
the persistence-before-acceptance rule. Apple transport tests additionally
cover exact SPKI hashing, malformed DER, invalid pins, fragmented/coalesced
stream reads, fail-closed protocol errors, and the irreversible transition to
application bytes. The Swift package passes, all Apple device targets build for
generic iOS and macOS, and `RivetWatchConnectivity` continues to build for
generic iOS and watchOS.

The next implementation agent owns bounded M2d: a disabled-by-default macOS
listener and per-install TLS identity provisioning boundary. It must cap
accepted connections before session allocation, close all connections on
disable/termination, use `RivetDeviceAppleTransport` for every accepted stream,
and expose deterministic state for tests. Keep Bonjour discovery, QR/manual
pairing UI, product UI, and product-repository changes out of that patch. Do
not add any iOS path that downloads or executes Racket code; executable mobile
logic must remain bundled with the reviewed application.

### M3 — second desktop host and Android client

Add the Windows gateway against the same iOS client, then bind Android
discovery/TLS streams to the existing Kotlin runtime and generated device API.

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
