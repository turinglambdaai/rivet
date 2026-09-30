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
