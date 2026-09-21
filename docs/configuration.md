# Project configuration

A Rivet application is configured by the `rivet.rktd` file at the project root.

New projects created with `raco rivet new` include explicit release identity and deployment-target metadata. Projects created with Rivet 0.1 remain valid: missing optional fields receive backwards-compatible defaults.

Example:

```racket
#hasheq(
  (name . "hello")
  (display-name . "hello")
  (version . "0.1.0")
  (build . 1)
  (identifier . "dev.rivet.hello")
  (macos-min-version . "14.0")
  (windows-min-version . "10.0.19041.0")
  (backend . "app/backend.rkt")
  (module . "backend")
  (entry . "start")
  (protocol . 1))
```

## Required settings

- `name` — application/project name.
- `backend` — relative path to the Racket backend module.
- `module` — backend module name used by the embedded runtime.
- `entry` — exported backend entry function.
- `protocol` — Rivet project protocol version. Rivet 0.2 supports protocol `1`.

## Release metadata

- `display-name` — user-visible application name. Defaults to `name` for legacy projects.
- `version` — application release version. Defaults to `0.1.0` for legacy projects.
- `build` — positive integer build number. Defaults to `1` for legacy projects.
- `identifier` — application/bundle identifier. Legacy projects derive `dev.rivet.<name>`.

These values feed packaging metadata instead of being duplicated in native platform templates.

## Deployment targets

- `macos-min-version` — two- or three-component macOS deployment version, for example `14.0` or `14.1`. The backwards-compatible default is `14.0`.
- `windows-min-version` — four-component Windows platform version, for example `10.0.19041.0`. The backwards-compatible default is `10.0.19041.0`.

The project configuration is the application-level source of truth:

- `raco rivet build` passes `macos-min-version` to both the generated SwiftUI host and Rivet's Swift runtime package through `RIVET_MACOS_MIN_VERSION`.
- macOS packaging writes the same value to `LSMinimumSystemVersion` in the final app `Info.plist`.
- `raco rivet verify` reads `LSMinimumSystemVersion` back from the packaged app and rejects a mismatch.
- `raco rivet build` passes `windows-min-version` to MSBuild through `RIVET_WINDOWS_MIN_VERSION`; the generated WinUI project uses that value as `WindowsTargetPlatformMinVersion`.

Do not edit deployment targets directly in generated `Package.swift` or `RivetHost.vcxproj` files. Change `rivet.rktd` so build, package, verification, CI, and future tooling all observe the same value.

## Compatibility

All release/deployment metadata above is optional when loading an older project. Rivet preserves the 0.1 behavior through centralized defaults, so upgrading the Rivet package does not require an immediate configuration migration.

New scaffolds write the values explicitly so application owners can review and intentionally change them.
