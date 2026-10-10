# Diagnostics and cleanup

Rivet's CLI exposes both human-readable and machine-readable toolchain diagnostics. The goal is to make native build failures inspectable without guessing which Racket runtime or platform tool was selected.

## `raco rivet doctor`

The normal doctor output reports the current operating system and architecture, the exact `racket` and `raco` executables, and the active Racket CS runtime artifacts selected by Rivet.

The runtime section includes:

- Racket version;
- include and library directories;
- DLL directory when present;
- the exact `petite.boot`, `scheme.boot`, and `racket.boot` files;
- on Windows, the selected Racket CS DLL and `.def` file;
- on macOS, the selected `Racket.framework`.
- on Linux, the selected static `libracketcs.a`.

It also reports the native build, dependency-audit, and optional production-signing tools used on the current platform.

This is intentionally more specific than printing only a Racket version. If multiple Racket installations are present, the paths shown by `doctor` are the artifacts Rivet will actually use for build/package operations.

### Actionable failures

When a required dependency is missing, human-readable doctor output ends with a `Fix next:` section. The remediation is deliberately conservative: it tells the developer which supported platform toolchain or Racket installation needs attention and what to rerun after the fix.

For example, an incomplete Windows C++ environment points to the Visual Studio 2022 / Build Tools `Desktop development with C++` workload and a Windows SDK; the Windows App SDK is a project package that Rivet restores during the build. An incomplete macOS environment points to `xcode-select --install` and the Xcode developer-directory selection when needed. Linux diagnostics check CMake, pkg-config, C++20, GTK4, `ldd`, and the embeddable static Racket CS library. If runtime discovery fails, Rivet asks for a complete Racket CS distribution and the same installation's `raco`.

Linux source builds may keep embedding artifacts outside the Racket installation used to run `raco`. In that case set `RIVET_RACKET_LIBRARY` to the exact `libracketcs.a`, `RIVET_RACKET_BOOT_DIR` to the directory containing the three boot files, and optionally `RIVET_RACKET_INCLUDE` / `RIVET_RACKET_LIB_DIR` when those also come from the custom prefix. `doctor` reports the resolved files before any build begins.

Optional release-only tools are not treated as development blockers. Missing Windows `signtool`, macOS notarization tooling, or Gatekeeper assessment support is reported as optional while development packaging remains available.

## `raco rivet doctor --json`

Use JSON mode from CI, Agents, editor integrations, or bug-report collectors:

```text
raco rivet doctor --json
```

The command writes a single JSON object to standard output and uses the same success/failure exit status as human-readable doctor output. Important top-level fields include:

- `os`
- `architecture`
- `supported`
- `usable`
- `racket-executable`
- `raco`
- `racket-version`
- `runtime`
- `runtime-error`
- `tools`

`runtime` contains the exact runtime artifact paths described above. `tools` contains platform-specific executable paths. Optional production tools such as Windows `signtool` or macOS notarization tools may be absent while normal development packaging remains usable.

JSON mode is intentionally data-only: it does not mix the human-readable banner or remediation prose into standard output. Automation should inspect `usable`, `runtime-error`, and `tools` and decide how to present or provision missing dependencies for its own environment.

## `raco rivet clean`

`clean` removes only Rivet-generated project directories:

```text
.rivet/
build/
dist/
```

It does not remove application source, `rivet.rktd`, native host source, or any other project files.

The operation is idempotent. If the project is already clean, the command succeeds without changing source files.

If one of the generated paths is a symbolic link, Rivet removes the link itself rather than recursively following it into an external directory. This keeps cleanup scoped to the project and avoids deleting data outside the generated-artifact boundary.

A normal workflow after changing toolchains or recovering from a stale native build is:

```text
raco rivet doctor
raco rivet clean
raco rivet build
```

For automated diagnostics, substitute `raco rivet doctor --json` and archive the resulting JSON with the failing build logs.

## Embedded runtime diagnostics

The embedded Windows, macOS, and Linux runtimes and the Racket backend emit one
JSON object per line for lifecycle and request-boundary events. This is separate
from RVT1: it does not add protocol frames, alter application payloads, or couple
the runtime to a logging provider.

```json
{"schema":"rivet.diagnostic.v1","layer":"native-client","event":"rpc-dispatch","status":"success","last_protocol_event":"response","request_id":42}
```

Every record contains:

- `schema`: always `rivet.diagnostic.v1`;
- `layer`: `native-runtime`, `abi-bridge`, `transport`, `protocol`,
  `native-client`, or `racket-backend`;
- `event` and `status`: the lifecycle boundary and `begin`, `success`, or
  `failure`;
- `last_protocol_event`: the most recently observed RVT1 message kind, or
  `none` before the first frame;
- optional `request_id` and `message` fields.

The event stream covers backend initialization, transport creation, Hello
handshake, per-RPC dispatch, cancellation, orderly shutdown, unexpected channel
closure, reader-loop failure, and backend exit. A failure record therefore says
whether the last known boundary was the Racket backend, the ABI bridge, RVT1
validation, transport I/O, or the native client.

Embedded applications are silent by default. This is important for native GUI
processes: on Windows, the first standard-error write can allocate a visible
console window. Applications should install a sink backed by their own logger
or crash reporter. The native runtimes keep explicit JSONL-to-stderr helpers
for command-line tools and development sessions:

```cpp
rivet::windows::RacketRuntimeConfig config;
config.diagnostic_sink = [](rivet::DiagnosticRecord const& record) {
  application_log(rivet::diagnostic_json_line(record));
};
```

The same `diagnostic_sink` field is available in the Linux runtime config. On
Apple platforms, pass `diagnosticSink:` to
`EmbeddedRacketConfiguration.resolvedDefault` or `RivetClient`; use
`RivetDiagnostics.standardError` only when stderr is intentional. On the
Racket side, `serve-fds` uses `current-rivet-diagnostic-sink`; direct `serve`
callers can pass `#:diagnostic-sink` explicitly. The parameter defaults to
`void`, so importing an embedded backend never acquires a console as a side
effect.

Diagnostic sinks run on runtime and request threads. They should be fast,
thread-safe, non-blocking, and must not call back into the same runtime. C++
sink exceptions are isolated from the application lifecycle.

Rivet never records RPC argument or result payloads. RPC begin records may name
the called API, and failure messages may contain application exception text;
treat the JSONL stream as operational log data and apply the same redaction and
retention policy as other crash reports. Racket-side messages are bounded to
4096 characters and avoid invoking custom printers on arbitrary raised values.
