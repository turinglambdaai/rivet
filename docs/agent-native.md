# Agent-native development

Rivet's product principle is **Human-first. Agent-native. Local by design.**

Human-first means the shipped interface follows each operating system's native
UI conventions. Agent-native means the development surface is discoverable,
machine-readable, deterministic, and verifiable. Local by design means the
Racket backend is embedded in the application process and normal application
work does not depend on a hosted control plane.

## Project discovery

Every generated project includes an `AGENTS.md` with its architecture and
ownership boundaries. An agent should begin with:

```bash
raco rivet inspect --json
raco rivet doctor --json
```

`inspect --json` emits a versioned project contract. It contains:

- project identity, release channel, RVT1 version, and absolute project root;
- the Racket backend module and entry procedure;
- native UI edit points for Windows, macOS, and Linux, including existence;
- honest maturity for desktop and mobile targets;
- generated-path state for `.rivet`, `build`, and `dist`;
- safe inspect, diagnose, build, run, package, verify, and cleanup commands;
- schema snapshot and backward-compatibility commands suitable for CI;
- a mutation flag for each command so an agent can distinguish read-only
  inspection from a build or cleanup operation;
- a structured `capability-sourcing` decision order for selecting a Racket
  package, native host API, FFI, CLI, sidecar, or owned implementation.

The command writes one JSON value to standard output and no explanatory banner,
making it safe for editors, coding agents, CI, and bug-report collectors.

## Schema evolution

An agent should not infer whether a backend API edit is safe from a generated
Swift or C++ diff. Generated projects include `rivet-schema.json`; keep that
intentional public contract in source control. Refresh it only when a change is
deliberate:

```bash
raco rivet schema --output rivet-schema.json
```

Then run the read-only gate before accepting later declaration changes:

```bash
raco rivet schema check rivet-schema.json --json
```

The JSON report separates `breaking-changes` from `compatible-additions` and
the command exits unsuccessfully for a break. RPC argument names/order/types
and result type, Event/State types, Record fields/order/types, existing Enum
cases/order, declaration removal, and the RVT1 protocol version are
compatibility-significant. Adding a new declaration is allowed. Regenerating
the baseline is a release-policy decision, not an automatic repair for a
failing check.

When `rivet-schema.json` exists, `raco rivet build` and commands that build
through it run this compatibility check before code generation. Keep the
explicit `schema check --json` step in CI for a focused report. Projects
without a baseline remain buildable during development, but `doctor` and
`inspect` report them as not release-ready.

`doctor --json` is the host-side complement. It reports the exact Racket CS
runtime, boot files, compiler/build tools, native dependency probes, and a
top-level `usable` result. It exits unsuccessfully when the current machine is
not ready, while the human form prints a `Fix next:` section.

## Capability sourcing

Rivet does not assume that every application capability must be implemented in
Racket, and it does not treat another language's larger package count as a
reason to abandon Racket. The engineering question is which boundary gives the
application the best combination of safety, latency, isolation, portability,
distribution cost, and maintainability.

`raco rivet inspect --json` exposes the following decision order under
`capability-sourcing`, so an agent can apply it without guessing or scraping
this page.

### 1. Search Racket first

Check the standard distribution, installed documentation, and Package Catalog:

```bash
raco docs <term>
raco pkg show
raco pkg catalog-show --all --only-names
raco pkg catalog-show --modules <package>
```

A candidate is not acceptable merely because it exists. Confirm its license,
Racket 9.0 CS compatibility, supported operating systems and architectures,
maintenance/security posture, transitive dependencies, and behavior in a clean
installation. Keep portable domain logic in `app/`; do not move it into a
native host just because one platform SDK also offers the operation.

### 2. Use the first-party native host for platform-owned behavior

UI controls, lifecycle, accessibility, notifications, activation, device APIs,
and other operating-system services belong in `windows/`, `macos-host/`, or
`linux/`. If shared Racket logic needs the result, expose the smallest typed
RPC/Event/State boundary and regenerate the native client. Do not route native
UI work through Racket FFI or invent a second ad-hoc IPC protocol.

### 3. Use FFI for a stable, high-frequency C boundary

Racket's `ffi/unsafe` can call C APIs directly without writing a C extension,
which is a strong answer for stable native libraries and frequent low-latency
calls. It is also process-unsafe: a bad signature, lifetime, callback, or thread
assumption can crash the whole embedded application.

Keep FFI code behind a small Racket module that exports checked, ordinary
Racket values. Document pointer ownership, allocation/free pairs, callback
lifetimes, blocking behavior, thread affinity, error translation, ABI/version
checks, and shutdown order. Ship the required library for every supported
platform/architecture or document a system dependency, then make package
verification prove that no undeclared developer-machine library leaked in.

### 4. Use a CLI for coarse-grained isolated work

A mature executable is often the lowest-risk integration for media conversion,
code generation, compilers, or other bounded jobs. Prefer `subprocess` when the
application needs control of I/O, timeouts, cancellation, or a process group;
`system*` is suitable for simple synchronous calls. Pass the executable and
each argument separately. Do not concatenate user data into `process`, a shell
string, `cmd.exe`, or `/bin/sh`; be especially cautious with Windows `.bat` and
`.cmd` files.

Probe the executable and its version before use. Bound input, output, runtime,
and concurrency; drain stdout and stderr concurrently so full pipes cannot
deadlock; close every returned port; check the exit status; and terminate the
process or process group on cancellation. Decide explicitly whether the tool is
bundled or a documented prerequisite, and verify its license, redistribution
terms, offline behavior, and presence in the packaged application.

### 5. Use a sidecar for a persistent or failure-isolated runtime

A sidecar is justified when an external runtime must stay warm, work is
streaming, the ABI is unstable, or a memory-unsafe/crash-prone component must
not share Rivet's process. It costs more than a CLI or FFI boundary. Own its
local authentication, version handshake, bounded protocol, readiness, timeout,
cancellation, logging, crash/restart policy, graceful shutdown, binary/runtime
distribution, upgrades, and offline behavior. Do not expose an unauthenticated
loopback service merely because it only listens locally.

### 6. Implement only when ownership is cheaper

Implement the missing capability in Racket or the native host when it is small,
security-critical, or substantially cheaper to own than another dependency and
its release surface. Record why the package, FFI, CLI, and sidecar alternatives
were rejected, then add conformance fixtures against the relevant format or
protocol instead of relying on a one-off example.

### Release gate for every external capability

Before calling an integration complete, verify:

- license and redistribution obligations;
- Racket 9.0 CS, OS, and architecture support;
- a pinned or otherwise reproducible dependency version;
- bounded input, output, runtime, concurrency, cancellation, and failure paths;
- no secrets in command arguments, logs, generated files, or source control;
- packaged-artifact dependency closure and clean-machine startup;
- offline behavior and an actionable diagnostic when the dependency is absent.

This decision system deliberately preserves Rivet's architecture: Racket owns
shared application logic, each platform owns its native UI, and integration
choices remain replaceable details rather than leaking into RVT1.

Primary Racket references: [package catalog commands](https://docs.racket-lang.org/pkg/cmdline.html),
[the foreign interface](https://docs.racket-lang.org/foreign/index.html), and
[subprocess lifecycle and pipe rules](https://docs.racket-lang.org/reference/subprocess.html).

## Deterministic ownership

The application owns these source paths:

- `app/` for shared Racket logic;
- `windows/` for WinUI 3/C++/WinRT UI;
- `macos-host/` for SwiftUI/AppKit UI;
- `linux/` for GTK4 UI;
- `rivet.rktd` and declared resources for product metadata and assets.

Rivet owns `.rivet/`, `build/`, and `dist/`. Agents should regenerate those
directories through the CLI rather than editing them. `raco rivet clean`
removes only those generated roots and refuses to follow directory symlinks.

## Verification loop

The normal autonomous loop is:

```bash
raco rivet acceptance --json
raco rivet build
raco rivet dev
raco rivet package
raco rivet verify
```

`rivet-acceptance.rktd` is the product-owned, executable definition of done.
It declares required evidence categories and the native platforms that must
run them. `acceptance` launches each suite without a shell, enforces time and
output bounds, checks exit status and declared artifacts, and returns a
machine-readable report suitable for a required CI check. See
[product acceptance evidence](product-acceptance.md).

The local operating system bounds only which suites can run locally, not the
required verification scope. Archive every platform leg's
`acceptance --json` report as a CI artifact and judge the union with
`raco rivet matrix <reports...> --json`: a change touching a guaranteed
desktop capability is incomplete until the required suites are proven on
every declared platform. Fix, then re-run only the affected platform's leg
and re-aggregate.

`build` validates the Racket schema and regenerates typed native clients.
`package` creates and immediately verifies a development distributable.
`verify` can audit the artifact again without rebuilding it. Production mode
adds platform trust requirements but deliberately leaves publisher credentials
under application control.

## Author the product interaction contract

An embedded backend makes domain behavior common; it does not make separately
authored native hosts behave alike. Before implementing a multi-host feature,
record one product-owned scenario table in the existing design/product spec:

`initial state -> user action -> visible result -> persisted effect ->
failure/recovery -> native presentation -> acceptance evidence`.

Agree on navigation hierarchy, selection versus activation, draft preservation,
focus after actions/dialogs, Escape order, undo, loading/empty/error/offline
states and language switching. Keep product tokens and strings in one product
source. Allow native controls, system typography, menu placement, materials,
date pickers and accessibility mechanisms to differ. A platform exception has
a user-visible fallback and its own evidence. Do not generalize a launcher's
hide-on-blur rule into every application.

### Review the running app, not an assumed mockup

An external design or prototyping tool is **optional**. For routine interaction
work, the packaged first-party native app is the prototype: define the scenario,
implement the narrow native change, run it, inspect the actual window, and
iterate. Use sketches when alternatives are expensive or hard to communicate;
never translate a Web prototype into a hidden cross-platform UI abstraction.

A fresh coding agent should review the scenario before implementation and
again against the real product: can the user discover the primary action, tell
whether a change is saved versus still a draft, cancel or recover without data
loss, complete the flow with keyboard/IME, and understand empty, loading and
error states? When a date chooser or sheet dismisses, specify whether that
commits, cancels, or preserves pending edits. Review layout hierarchy, text
clipping, scaling, contrast, and native affordances from a captured real window
where the platform supports capture. Screenshots are supporting evidence, not a
machine-verifiable declaration that a design is beautiful or usable.

For a product's critical flow, use the native platform drivers in
[native UI end-to-end testing](native-ui-testing.md) to exercise the packaged
application, not a toy view or a backend-only test. Verify accessible
identifiers, real focus and input routing, persisted effects across restart,
and failure/recovery. Classify missing screen captures, human design review,
or platform runs as *unverified* rather than passed. Let the product's existing
`rivet-acceptance.rktd` declare required native suites; do not silently add
a universal screenshot-only gate or promise automatic aesthetic judgment.

Rivet owns platform adapters, typed contracts, discovery, diagnostics and
evidence orchestration. The product owns information architecture, interaction
meaning and brand. Guidance belongs in this guide and product specifications;
it does not justify a cross-platform UI DSL, shared selector language, new
mandatory theme engine or business logic inside hosts. Move a repeated
mechanism upstream only after two products demonstrate the same boundary.

Use [Apple's design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)
for hierarchy, focused tasks and feedback; use the relevant platform's
keyboard/focus and accessibility guidance when choosing the native control.
See [Windows keyboard interactions](https://learn.microsoft.com/en-us/windows/apps/develop/input/keyboard-interactions)
and [GNOME accessibility](https://developer.gnome.org/hig/guidelines/accessibility.html).
For each declared desktop, exercise the same user outcome through native input,
record accessibility state and persisted effects, and supplement it with
screenshots at representative sizes/themes. Visual similarity alone is not
parity; equal RPC responses alone do not prove the UI interaction.

## A path for a user who does not read source

The useful goal is a reproducible, reviewable delivery loop with little
engineering knowledge required from the product owner. It is not a promise
that arbitrary generated applications are correct without review.

Start with one narrow product brief: who uses it, one primary task, data and
privacy boundaries, declared platforms and what success looks like. The agent
then uses the existing scaffold, inspect/doctor, schema and acceptance tools
to deliver one packaged vertical slice. The owner reviews the running task,
screenshots, error/recovery behavior and data export, rather than approving an
unexplained code diff. The agent records the build and evidence so another
agent can reproduce the result from a clean checkout.

Beginner guidance and recipes should explain this loop and link to the
canonical CLI documentation. Actual tooling gaps belong in the existing CLI:
errors need stable codes, useful next actions and honest unavailable states.
Do not add a second orchestration framework or conceal missing platform
evidence behind an “AI verified” label. A tutorial is validated only when a
fresh session can follow it without undocumented local state. Validate first
with the taskboard reference, then one real product, and record the point at
which human product/security judgment is required.

## Current boundary

This contract makes project discovery, diagnostics, mutation boundaries,
acceptance orchestration, and artifact verification agent-native. Rivet does
not itself visually inspect every first-party product UI. Windows/macOS/Linux
UI automation, accessibility-tree inspection, screenshots, and interaction
traces remain product-owned suites and should not be claimed until those
native adapters are declared and green in the acceptance manifest.
