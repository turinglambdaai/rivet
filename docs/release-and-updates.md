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

Run `raco rivet release`. The result is a signed MSI on Windows, a signed/notarized DMG on macOS, or an Ed25519-signed self-contained `.tar.gz` on Linux, plus a versioned portable zip, channel manifest, CycloneDX SBOM, and `THIRD_PARTY_NOTICES.txt`. The channel manifest describes the portable zip; platform installers remain direct-download artifacts. `release --development` exercises the same flow without production platform signing, but the update manifest still requires its independent Ed25519 key.

On Linux the release additionally builds native system installers: a `.deb` (dpkg-deb, unprivileged, installs under `/opt/<name>` with a desktop entry), an `.rpm` (rpmbuild BUILDROOT, distro-independent), and an `.AppImage` (bundled GTK4 dependency closure, so the same file runs on older distributions). Select the set with the `linux-formats` project setting; the signed tar.gz is always produced as the self-contained installer, while the portable zip is the update-channel payload. Package-manager installs upgrade through the package manager; AppImage installs upgrade by replacing the AppImage. AppImage packaging requires a `linux-icon` PNG in rivet.rktd — the format mandates a top-level icon and Rivet fails closed rather than shipping a placeholder.

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

The updater verifies in this order:

1. Ed25519 signature and expected key ID.
2. Application identity, channel, SemVer precedence, minimum version, rollout bucket, platform, and architecture.
3. Download byte limit and signed expected size.
4. SHA-256 of the complete downloaded portable archive.
5. Platform code signature/trust of the application carried by that archive as part of release and package verification.

Only then may the native adapter install. A failed installation, restart, or health check invokes the rollback callback only when the signed manifest permits rollback. The adapter extracts the portable archive into a new versioned location, preserves the previous installation until the replacement passes its health check, and uses the platform-specific application signature where available. Direct MSI/DMG/deb/rpm/AppImage installs retain their own platform transaction or package-manager behavior. Private keys never belong in the repository. Generate and store them outside the checkout, for example:

```bash
openssl genpkey -algorithm Ed25519 -outform DER -out update-private.der
openssl pkey -inform DER -in update-private.der -pubout -outform DER -out update-public.der
```

Embed only `update-public.der` (or its bytes) in the native host. Key rotation is explicit through `key_id`; ship a client trusting the next public key before signing releases exclusively with it.

## Application API

Require `rivet/distribution`. `fetch-update-manifest` verifies before parsing, `select-update` applies channel/version/rollout/platform policy, and `download-update` enforces limits and hashes. `execute-install-plan!` delegates elevation and process replacement to a native adapter while owning the health and rollback state machine. Pass `#:journal-path` to atomically persist every destructive phase; on the next start, `recover-install-plan!` accepts only the exact same signed candidate and paths before committing a previously healthy transaction or retrying its idempotent rollback. A durable adapter should use absolute paths, keep the backup until commit, and make its restart callback return after starting the replacement so the health check can run.

- `stable` accepts release SemVer versions only.
- `beta` accepts stable versions and `beta` prereleases.
- `dev` accepts any valid SemVer version.

Build metadata does not affect version precedence.

## External validation points

CI can test signing, tampering, selection, hashing, packaging structure, and native compilation without publisher identities. A real release still needs the publisher's Authenticode certificate or Apple Developer ID/notary profile, an Ed25519 update key, an HTTPS artifact origin, and a final install/upgrade/rollback exercise on supported OS versions.
