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
to-live-session revocation. `inspect --json` reports
this as `framework-core` and separately lists the listener, TLS adapter,
platform secure-storage adapter, discovery, and product UI as pending. No
product repository or UI was changed.

## Next implementation handoff

The next implementation agent owns one bounded M2a slice: the Apple secure-
storage adapter. Do not add a listener, discovery, TLS, pairing UI, product UI,
or product-repository changes in the same patch.

Add a `RivetDeviceAppleSecurity` Swift product/target that depends on
`RivetDevice` and implements `RivetDevicePairingStore` with Security.framework
generic-password items:

- namespace items by an initializer-supplied service string; use the paired
  device UUID as the account and never put the display name or credential in a
  label, error, or log;
- store one versioned Codable envelope containing the non-secret metadata and
  32-byte credential as the Keychain value, with synchronizable disabled and a
  device-local accessibility class suitable for background reconnect;
- make save an add-or-update operation, load exact by UUID, list only the
  configured service, and remove idempotent;
- reject wrong envelope versions, malformed metadata, wrong fingerprints, and
  wrong credential lengths with stable typed errors that contain no stored
  bytes;
- put Security.framework calls behind an injectable narrow client so unit tests
  do not mutate or prompt against the developer's real Keychain.

Acceptance evidence for M2a:

1. Deterministic tests cover add, update, exact load, service-scoped listing,
   idempotent removal, malformed/version-mismatched entries, Security status
   mapping, and secret-free error descriptions.
2. The full Swift package tests pass with the documented Racket include path.
3. `RivetWatchConnectivity` still builds for generic iOS 16 and watchOS 9, and
   the new security target builds for generic iOS and macOS.
4. `inspect --json` moves only `secure-storage-adapter` from `pending` to
   `implemented`; listener/TLS/discovery/product UI remain pending.
5. The implementation agent updates this section with evidence and commits the
   patch. A design/review pass should approve it before starting the bounded
   session-preface codec.

### M3 — second desktop host and Android client

Add the Windows gateway against the same iOS client, then bind Android
discovery/TLS streams to the existing Kotlin runtime and generated device API.

### M4 — standalone mobile hosts

Only after the shared contract is stable, pursue Android JNI/portable Racket +
Compose and the corresponding Apple embedded-runtime application flow. Each
requires generated projects, lifecycle/process-death tests, signing, packaging,
and device/emulator round trips before developer-preview status.

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
