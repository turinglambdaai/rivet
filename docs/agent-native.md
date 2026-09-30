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
- a mutation flag for each command so an agent can distinguish read-only
  inspection from a build or cleanup operation.

The command writes one JSON value to standard output and no explanatory banner,
making it safe for editors, coding agents, CI, and bug-report collectors.

`doctor --json` is the host-side complement. It reports the exact Racket CS
runtime, boot files, compiler/build tools, native dependency probes, and a
top-level `usable` result. It exits unsuccessfully when the current machine is
not ready, while the human form prints a `Fix next:` section.

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
