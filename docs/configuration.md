# Project configuration

A Rivet application is configured by the `rivet.rktd` file at the project root.

New projects created with `raco rivet new` include explicit release identity and deployment-target metadata. Projects created with Rivet 0.1 remain valid: missing optional fields receive backwards-compatible defaults.

Example:

```racket
#hasheq(
  (name . "hello")
  (display-name . "hello")
  (publisher . "Example Company")
  (version . "0.1.0")
  (build . 1)
  (identifier . "dev.rivet.hello")
  (release-channel . stable)
  (url-schemes . ("hello"))
  (file-associations . (#hasheq((extension . ".hello")
                                (description . "Hello Document"))))
  (resources . ("assets" "locales/en.json"))
  (device-rpcs . (current-score refresh-score))
  (windows-icon . "branding/app.ico")
  (macos-icon . "branding/app.icns")
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
- `publisher` — human-readable publisher used by Windows installer metadata and Apps & Features. Defaults to `display-name` for legacy projects; do not use the reverse-DNS `identifier` here.
- `version` — application release version. Defaults to `0.1.0` for legacy projects.
- `build` — positive signed 64-bit integer build number. Defaults to `1` for legacy projects.
- `identifier` — application/bundle identifier. Legacy projects derive `dev.rivet.<name>`.

These values feed packaging metadata and generated native constants instead of
being duplicated in platform templates. Swift and Kotlin expose them on
`RivetGeneratedConfig`; C++ exposes `kDisplayName`, `kVersion`, `kBuild`,
`kIdentifier`, and `kReleaseChannel` beside the generated module/entry names.
The generated macOS host uses `displayName` for its `WindowGroup` title.

The build also stages this identity for backend code. Require `rivet/app-info`
(or the aggregate `rivet` module) instead of hardcoding a second version:

```racket
(require rivet/app-info)

(define current-version (app-version))
(define update-channel (app-release-channel))
```

`current-app-info` returns all six fields as an `app-info` value. The
convenience procedures `app-name`, `app-display-name`, `app-version`,
`app-build`, `app-identifier`, and `app-release-channel` read the same staged
metadata. Missing or malformed metadata fails explicitly; Rivet does not guess
release identity from the executable name.

## Distribution and activation metadata

- `release-channel` — `stable`, `beta`, or `dev`; defaults to `stable`. The value is signed into update manifests and must match the client's selected channel.
- `url-schemes` — a list of RFC 3986 scheme names. Packaging registers these with the native OS; the native host receives activations.
- `file-associations` — a list of hashes with an `extension` beginning with `.` and an optional `description`. Packaging emits native document/installer metadata.

These settings describe native registration only. They do not add messages to RVT1 or create a shared UI abstraction.

## Companion-device API

- `device-rpcs` — an explicit list of backend RPC symbols exposed through the
  generated Apple companion API. It defaults to the empty list, so upgrading
  an existing project does not expose backend methods to another device.

Every name must identify a declared RPC and fit the bounded RivetDevice route
syntax. Selected argument/result types must be Codable-compatible; `Any` is
rejected. Generation produces Swift request types, typed
`RivetDeviceClient` methods, and `RivetDeviceRouter.registerGeneratedBackend`.
The exported names are included in `rivet-schema.json`: removing one is a
breaking change, while adding one is compatible. See
[typed device communication](device-communication.md).

## Application resources and icons

- `resources` — a list of project-relative files or directories copied into the application resource root while preserving their relative paths. Generated/control roots (`.git`, `.rivet`, `build`, and `dist`) and symbolic links are rejected so a release cannot accidentally capture repository metadata, stale output, or files outside the project.
- `windows-icon` — an optional project-relative `.ico` file compiled into newly generated Windows hosts.
- `macos-icon` — an optional project-relative `.icns` file copied into the app bundle and declared through `CFBundleIconFile`.
- `linux-icon` — an optional project-relative `.png` file installed as the desktop icon (`/usr/share/pixmaps`, referenced by the generated `.desktop` entry) and used as the AppImage top-level icon. AppImage packaging fails closed without it.
- `linux-formats` — an optional subset of `("deb" "rpm" "appimage")` selecting which native Linux installer formats `raco rivet release` builds. The default builds all three; the signed tar.gz update payload is always produced regardless.

Packaged resources live under `app/` inside the platform resource root. Racket code should use `resource-path` from `rivet/resources` (also re-exported by `rivet`) instead of guessing an executable-relative path. The filename `rivet-app-info.rktd` at this root is reserved for Rivet's generated application identity:

```racket
(require rivet/resources)

(define defaults
  (call-with-input-file (resource-path "config" "defaults.rktd") read))
```

SwiftPM `resources` declarations in the macOS host package are incompatible
with packaging: `Bundle.module` looks for its bundle at the `.app` root next
to `Contents/`, which is unsealed content that `codesign` rejects, and the
generated bundle is not itself a codesignable bundle. `raco rivet package`
therefore fails closed when the Swift package declares resources. Migrate by
declaring the same data in `resources` above and reading it in native code
from `Contents/Resources/app`:

```swift
let root = Bundle.main.resourceURL   // Contents/Resources (packaged)
let dataURL = root!.appendingPathComponent("app/locales/en.json")
```

During `raco rivet dev`, the root is `.rivet/stage/app`. Windows and Linux packages keep it beside the executable as `app/`; macOS packages keep it at `Contents/Resources/app`. Native UI code can use those same platform-native locations. Set `RIVET_RESOURCE_ROOT` or parameterize `current-resource-root` only for tests and specialized hosts.

Product resources must be declared explicitly; Rivet does not infer a resource
contract from directory names. For example, a product that shares translations
and an emoji catalog across its native hosts should configure:

```racket
(resources . ("shared/i18n" "shared/emoji.json"))
```

The preserved paths are then `.rivet/stage/app/shared/i18n/...` during a build,
`app/shared/i18n/...` in Windows and Linux packages, and
`Contents/Resources/app/shared/i18n/...` in a macOS application. Native host
code should resolve that platform resource root and append the same
`shared/...` relative path. Do not copy product files into `stage/res`: `res`
is Rivet's embedded-backend area and contains `core.zo`, while `app` is the
verified application-resource contract. This explicit declaration keeps build,
package, and `raco rivet verify` behavior identical on all three platforms.

Projects created before this feature remain valid because all three settings are optional. To embed a Windows icon in an older generated host, add Rivet's conditional `RIVET_WINDOWS_ICON_RC` `ResourceCompile` item from the current host template or regenerate the host project while preserving application UI sources.

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
