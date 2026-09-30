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
raco rivet build
raco rivet dev
raco rivet package
raco rivet verify
```

`build` validates the Racket schema and regenerates typed native clients.
`package` creates and immediately verifies a development distributable.
`verify` can audit the artifact again without rebuilding it. Production mode
adds platform trust requirements but deliberately leaves publisher credentials
under application control.

## Current boundary

This contract makes project discovery, diagnostics, mutation boundaries, and
artifact verification agent-native. It does not yet provide automated visual
inspection of every first-party native UI. Windows/macOS/Linux UI automation,
accessibility-tree inspection, screenshots, and interaction traces remain a
separate product layer and should not be claimed until those adapters exist.
