# Release and updates

Rivet keeps distribution services outside RVT1. The application protocol and embedded Racket lifecycle do not know how an installer, update channel, or signing key works. Applications opt into `rivet/distribution`, while `raco rivet release` composes the existing build, package, platform signing, verification, installer, compliance, and update-manifest stages.

## Release command

Production releases require the platform signing configuration plus these update variables. Windows needs the Authenticode settings and macOS the Developer ID/notary settings; Linux needs `RIVET_LINUX_SIGN_PRIVATE_KEY` and `RIVET_LINUX_SIGN_KEY_ID` (see [production signing](production-signing.md)).

```text
RIVET_UPDATE_BASE_URL=https://downloads.example.com/my-app
RIVET_UPDATE_PRIVATE_KEY=/secure/path/update-ed25519-private.der
RIVET_UPDATE_KEY_ID=release-2026
RIVET_PREVIOUS_VERSION=1.4.2                 # optional rollback metadata
RIVET_MINIMUM_UPDATABLE_VERSION=1.0.0        # optional; defaults to 0.0.0
RIVET_UPDATE_ROLLOUT=100                     # optional; 0..100
```

Run `raco rivet release`. The result is a signed MSI on Windows, a signed/notarized DMG on macOS, or an Ed25519-signed self-contained `.tar.gz` on Linux, plus a versioned portable zip, channel manifest, CycloneDX SBOM, and `THIRD_PARTY_NOTICES.txt`. The signed channel always includes the portable zip; Windows also includes the exact MSI, and Linux includes the exact AppImage when that format is enabled. One feed therefore serves each supported install shape without deriving sibling URLs or trusting unsigned sidecars. DMG, deb, rpm, and tar.gz remain direct-download or package-manager artifacts. `release --development` exercises the same flow without production platform signing, but the update manifest still requires its independent Ed25519 key.

On Linux the release additionally builds native system installers: a `.deb` (dpkg-deb, unprivileged, installs under `/opt/<name>` with a desktop entry), an `.rpm` (rpmbuild BUILDROOT, distro-independent), and an `.AppImage` (bundled GTK4 dependency closure, so the same file runs on older distributions). Select the set with the `linux-formats` project setting. The signed tar.gz and portable zip are always retained as release assets. When AppImage is enabled, the signed manifest carries both the portable ZIP and AppImage entries, each with its exact URL, size, SHA-256, and installer kind; release also writes a human-facing `.AppImage.sha256` sidecar, but clients trust the signed feed. Package-manager installs upgrade through the package manager; AppImage installs use Rivet's verified atomic replacement. AppImage packaging requires a `linux-icon` PNG in rivet.rktd — the format mandates a top-level icon and Rivet fails closed rather than shipping a placeholder.

Applications that deliberately ship without an online update channel can run `raco rivet release --without-updates`. The command still builds, packages, platform-signs, verifies, and emits the installer, SBOM, and third-party notices; it skips only the channel manifest and does not read any `RIVET_UPDATE_*` credentials. Combine it with `--development` to exercise the unsigned release flow before publisher credentials exist. Omitting `--without-updates` keeps the fail-closed behavior above: all three update settings are required, and a partial configuration is an error.

WiX Toolset v4 or later is required to build the Windows MSI. macOS uses the system `hdiutil`. Rivet signs the final MSI/DMG as well as the contained application. On Linux the final tarball is signed and, because the archive is deterministic, `raco rivet verify --production` re-derives it from the package and checks the detached signature.

## Multi-platform release matrices

Every installer format builds natively on its platform, so a family
release is a per-platform matrix plus one aggregation step:

| Leg | Runner | Produces |
| --- | ------ | -------- |
| Windows x64 / ARM64 | `windows-latest` / `windows-11-arm` | MSI + portable zip + per-platform manifest |
| macOS arm64 | `macos-latest` | DMG + zip + manifest |
| macOS x64 | `macos-15-intel` | DMG + zip + manifest |
| Linux x64 / ARM64 | `ubuntu-latest` / `ubuntu-24.04-arm` | deb + rpm + AppImage + tar.gz + manifest |

Conventions that keep the legs composable:

- Every leg runs `raco rivet release` in the checkout of the same tag, so
  version/build/identifier are identical by construction — the family
  compose step below rejects any disagreement.
- Artifacts follow the family naming (`<product>-<version>-<os>-<arch>`
  plus extension), so the update base URL is one flat directory.
- Install the Racket CS runtime matching the runner architecture (the
  same matrix Rivet's own `architectures.yml` exercises; the checksum-
  pinned `setup-embed-racket` action covers the Linux legs).
- After every leg uploaded its `update-<channel>.json`, one aggregation
  job runs:

  ```bash
  raco rivet manifest-compose     windows/update-stable.json macos-arm64/update-stable.json     macos-x64/update-stable.json linux/update-stable.json     --output update-stable.json
  ```

  with `RIVET_UPDATE_PRIVATE_KEY` and `RIVET_UPDATE_KEY_ID` set. It verifies
  every leg's Ed25519 signature and key ID before folding the authenticated
  payloads into one signed family manifest (one artifact per
  platform/architecture, all metadata fields verified identical) — replacing
  the per-product hand-rolled merge scripts.

The portable zip beside every installer is produced by the same `release`
run; the family update feed and locked-down machines consume it directly.

## Update trust model

HTTPS protects transport, but it is not the root of update trust. A manifest contains an exact byte payload and an Ed25519 signature. The signed payload identifies the application, version, build, stable/beta/dev channel, staged rollout percentage, minimum updatable version, rollback predecessor, and every platform artifact's URL, byte size, SHA-256, installer kind, and arguments.

Manifest policy is validated as a whole before signing or accepting it. Every
release has at least one positive-size artifact; minimum and previous versions
are older than the release; and platform/architecture/installer identities are
unique. Separate portable and AppImage artifacts for the same Linux target are
valid because their installer identities differ. Versioned wrapper, manifest,
signature, and artifact objects are closed schemas; unknown fields and trailing
JSON values fail instead of being silently ignored.

The updater verifies in this order. The signed payload stays as opaque bytes
until the Ed25519 check succeeds; unauthenticated input never reaches the
manifest JSON parser.

1. Ed25519 signature and expected key ID.
2. Application identity, channel, SemVer precedence, minimum version, rollout bucket, platform, and architecture.
3. Download byte limit and signed expected size.
4. SHA-256 of the complete downloaded portable archive.
5. Platform code signature/trust of the application carried by that archive as part of release and package verification.

Only then may the native adapter install. A failed installation, restart, or health check invokes the rollback callback only when the signed manifest permits rollback. The adapter extracts the portable archive into a same-filesystem staging location, verifies the staged platform signature, atomically preserves the previous installation, and keeps that backup until the replacement passes its health check and commits. Direct MSI/MSIX/DMG/PKG/deb/rpm installs retain their own platform transaction or package-manager behavior; Rivet's portable adapter rejects them instead of silently bypassing elevation, receipts, or repository trust. AppImage replacement is supported as a portable Linux policy. Private keys never belong in the repository. Generate and store them outside the checkout, for example:

```bash
openssl genpkey -algorithm Ed25519 -outform DER -out update-private.der
openssl pkey -inform DER -in update-private.der -pubout -outform DER -out update-public.der
```

Embed only `update-public.der` (or its bytes) in the native host. Key rotation is explicit through `key_id`; ship a client trusting the next public key before signing releases exclusively with it.

## Application API

Require `rivet/distribution`. `fetch-update-manifest` verifies before parsing, `select-update` applies channel/version/rollout/platform policy, and `download-update` enforces limits and hashes. On Linux, pass `(current-install-kind)` as `#:install-kind`: AppImage and portable installs only select their matching payload, while deb/rpm installations return `package-manager` and do not consume the AppImage feed. `prepare-platform-installation` turns a verified portable ZIP or Linux AppImage into Rivet's first-party atomic replacement; pass its result to `execute-platform-installation!`. The application supplies restart and health callbacks because it owns its process model and readiness signal. On Windows and macOS the default staged-payload verifier requires Authenticode or a deep strict code signature; development builds may inject an explicit verifier.

Applications that need an in-app progress UI should use `make-updater` instead
of rebuilding this orchestration. `updater-check!` performs the authenticated
check and selection, `updater-download!` starts one bounded background worker,
and `updater-state` returns an immutable JSON-safe polling snapshot.
`updater-cancel!` interrupts an active transfer. The managed worker uses
monotonic no-progress and total deadlines, cleans partial files on cancellation
or timeout, and rejects concurrent check/download operations. It deliberately
stops at a verified downloaded artifact: installation consent, elevation,
restart, and health policy remain with the native host and the platform
installation APIs below.

Persist one rollout bucket from 0 through 99 per installation and pass it to
`make-updater`; generating a fresh value for every check would make staged
rollouts unstable. The managed API accepts only Rivet's supported Windows,
macOS, and Linux x64/ARM64 targets and fails closed on an unknown architecture.
Its polling phase vocabulary is stable: `idle`, `checking`, `available`,
`up-to-date`, `downloading`, `downloaded`, `cancelled`, and `error`. A failed
or cancelled transfer keeps the authenticated candidate for an explicit retry;
a new check clears it before fetching current policy.

Pass `#:journal-path` to atomically persist every destructive phase. On the next start, reconstruct the same installation and call `recover-platform-installation!`; it accepts only the exact same signed candidate and absolute download/target/backup paths. An interruption before health restores the prior payload. An interruption during the idempotent commit repeats backup cleanup instead of rolling a healthy application back.

Portable execution and recovery share an exclusive lock derived from the
installation target identity, independent of a caller-selected backup path.
The lock serializes threads and processes before
they can touch staging, backup, marker, or journal state; a competing updater
fails explicitly. Its sibling lock file is intentionally persistent and empty:
the operating-system lock on that file carries ownership, so a crash releases
ownership without making stale-file cleanup part of recovery.

The lower-level `make-install-plan`, `execute-install-plan!`, and `recover-install-plan!` remain available for product-specific native installers. `execute-install-plan!` accepts `#:commit` for idempotent post-health cleanup. Elevation stays behind those adapters and never enters RVT1 or the embedded runtime.

- `stable` accepts release SemVer versions only.
- `beta` accepts stable versions and `beta` prereleases.
- `dev` accepts any valid SemVer version.

Build metadata does not affect version precedence.

## Update API keyword contract

The hand-written Racket side of the updater is a small, stable surface. These
are the complete keyword contracts; a keyword not listed here is rejected at
runtime, which is exactly how shipped releases have failed on user machines.
`raco rivet doctor --release` scans host source against the installed rivet's
own contracts, so drift fails in CI instead:

- `fetch-update-manifest` accepts `#:key-id` `#:maximum-bytes` `#:connect-timeout-seconds` `#:idle-timeout-seconds`.
- `select-update` accepts `#:install-kind`.
- `download-update` accepts `#:on-progress` `#:progress-every` `#:stall-timeout-seconds` `#:total-timeout-seconds`.
- `fetch-sibling-asset` accepts `#:sha256` `#:maximum-bytes` `#:on-progress` `#:connect-timeout-seconds` `#:idle-timeout-seconds`.

Adding a keyword to one of these functions is a compatible addition for the
contract scanner; removing or renaming one is breaking and needs a release
note.

## Release gate

Run `raco rivet doctor --release` in release CI before building installers.
One command and one exit code cover: generated client files match a fresh
regeneration (`raco rivet generate --check` runs that single check
standalone), the committed schema baseline accepts the current backend,
hand-written host sources call the update API only with keywords the
installed rivet accepts, and every `rivet.git#...` pin in the repository is
non-empty and consistent with the installed rivet release. A failing gate
means the release would otherwise ship a stale version stamp, a schema
break, or an updater call that fails only on user machines.

## Host-side updates on macOS

The engine API above covers applications whose update flow runs in Racket. Applications whose macOS host owns the whole flow natively should not hand-roll it: the Swift package exposes `RivetUpdate` (`platform/macos`), a shared update client for installed `.app` bundles. It performs the authenticated check against the same signed wrapper the engine verifies (`RivetUpdateService.check`), a bounded delegate-driven artifact download with progress and cancellation (`downloadAndInstall`), SHA-256 and size verification against the signed manifest, `ditto` unpacking, a bundle-version confirmation, and an atomic swap-with-rollback that relaunches the application.

Applications configure four facts — feed URL, Ed25519 public key, key id, and bundle name — and keep their own UI. Configuration fails closed at construction: non-HTTPS feeds outside loopback drills, malformed bundle names, empty key ids, and public keys that are not the 32 raw Ed25519 bytes are rejected before any transfer starts. The downloader rejects a definitive `Content-Length` that disagrees with the signed size immediately instead of downloading a wrong artifact to the end, and the file on disk must match the signed size even when the response carried no length.

The downloader is delegate-driven on purpose. Byte-iterating `URLSession.AsyncBytes` can park its continuation forever when the stream's end-of-stream flag never surfaces (observed live against the GitHub CDN: all bytes delivered, the loop never wakes, the update sheet sticks at 100%). Delegate completion callbacks are definitive, and the request/resource timeout intervals bound a silent stall. Two UX rules follow for hosts driving this from SwiftUI:

- A running transfer always offers an explicit Cancel affordance; task cancellation invalidates the session, so the awaited call always resumes promptly.
- The update surface stays dismissable by gesture except during the final swap-and-relaunch step, which terminates the process anyway.

The handoff at the end of an install owns two further traps the module encodes: the spawned swap script takes ownership of the work directory (an eager `defer` cleanup would race the script's grace sleep and destroy the payload — call `RivetUpdateService.cleanupStaleWorkDirectories()` at startup to sweep directories left by crashed attempts), and a presented SwiftUI sheet silently vetoes `NSApplication.terminate`, so the module ends every sheet, terminates, and stops the run loop if the quit was deferred — a surviving old process could otherwise hold a single-instance lease and quietly kill the relaunched update.

## Host-side updates on Windows and Linux

Windows and Linux use the same authenticated client rather than reimplementing
the macOS Swift module in C++: `make-updater` is the shared trust and transfer
boundary. It verifies the Ed25519 wrapper before parsing, selects the artifact
for the current install shape, enforces deadlines and byte limits, and verifies
the signed size and SHA-256. Release manifests include both the portable ZIP
and the native MSI on Windows, and both the portable ZIP and AppImage on Linux;
pass `#:install-kind 'portable`, `'msi`, or `'appimage` so a host never derives
or sidecar-trusts a sibling URL.

Only the final OS handoff remains native, and Rivet ships that too:

- Windows hosts link `rivet-host.vcxproj` and include
  `platform/windows/update/update_handoff.hpp`. After the managed updater has
  produced a verified MSI, `MsiHandoff::LaunchVerifiedInstaller` creates a
  process-specific handoff, waits a bounded time for the old process to exit,
  runs `msiexec /passive /norestart`, records a failure for the next launch,
  and relaunches the application. The release callback runs after the helper
  exists so single-instance ownership is dropped before the new process starts.
  `ConsumeFailure` and `CleanupStaleAttempts` complete the startup lifecycle.
- Linux keeps `prepare-platform-installation` /
  `execute-platform-installation!` as the blessed AppImage swap path; GTK hosts
  must not duplicate it. The linked `rivet::platform` target exposes
  `DetectLinuxInstallKind` for pre-download UI policy and
  `RelaunchInstalledAppImage` for the post-commit exec handoff, including lease
  release. deb/rpm installations remain owned by the system package manager.

The product supplies application id, current version, feed URL, public key,
key id, a persistent rollout bucket, and localized UI. It does not own manifest
parsing, cryptography, download watchdogs, staging, or installer scripts.

## External validation points

CI can test signing, tampering, selection, hashing, packaging structure, and native compilation without publisher identities. A real release still needs the publisher's Authenticode certificate or Apple Developer ID/notary profile, an Ed25519 update key, an HTTPS artifact origin, and a final install/upgrade/rollback exercise on supported OS versions.
