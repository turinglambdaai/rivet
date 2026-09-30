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

Run `raco rivet release`. The result is a signed MSI on Windows, a signed/notarized DMG on macOS, or an Ed25519-signed self-contained `.tar.gz` on Linux, plus a channel manifest, CycloneDX SBOM, and `THIRD_PARTY_NOTICES.txt`. `release --development` exercises the same flow without production platform signing, but the update manifest still requires its independent Ed25519 key.

WiX Toolset v4 or later is required to build the Windows MSI. macOS uses the system `hdiutil`. Rivet signs the final MSI/DMG as well as the contained application. On Linux the final tarball is signed and, because the archive is deterministic, `raco rivet verify --production` re-derives it from the package and checks the detached signature.

## Update trust model

HTTPS protects transport, but it is not the root of update trust. A manifest contains an exact byte payload and an Ed25519 signature. The signed payload identifies the application, version, build, stable/beta/dev channel, staged rollout percentage, minimum updatable version, rollback predecessor, and every platform artifact's URL, byte size, SHA-256, installer kind, and arguments.

The updater verifies in this order:

1. Ed25519 signature and expected key ID.
2. Application identity, channel, SemVer precedence, minimum version, rollout bucket, platform, and architecture.
3. Download byte limit and signed expected size.
4. SHA-256 of the complete downloaded installer.
5. Platform installer signature/trust as part of release and package verification.

Only then may the native adapter install. A failed installation invokes the rollback callback only when the signed manifest permits rollback. MSI supplies transactional rollback; a macOS adapter should preserve the previous `.app` until the replacement has launched successfully; a Linux adapter should extract the tarball into a new versioned directory and keep the previous directory until the replacement has launched successfully. Private keys never belong in the repository. Generate and store them outside the checkout, for example:

```bash
openssl genpkey -algorithm Ed25519 -outform DER -out update-private.der
openssl pkey -inform DER -in update-private.der -pubout -outform DER -out update-public.der
```

Embed only `update-public.der` (or its bytes) in the native host. Key rotation is explicit through `key_id`; ship a client trusting the next public key before signing releases exclusively with it.

## Application API

Require `rivet/distribution`. `fetch-update-manifest` verifies before parsing, `select-update` applies channel/version/rollout/platform policy, `download-update` enforces limits and hashes, and `execute-install-plan!` delegates elevation/process replacement to a native adapter while owning the rollback state machine.

- `stable` accepts release SemVer versions only.
- `beta` accepts stable versions and `beta` prereleases.
- `dev` accepts any valid SemVer version.

Build metadata does not affect version precedence.

## External validation points

CI can test signing, tampering, selection, hashing, packaging structure, and native compilation without publisher identities. A real release still needs the publisher's Authenticode certificate or Apple Developer ID/notary profile, an Ed25519 update key, an HTTPS artifact origin, and a final install/upgrade/rollback exercise on supported OS versions.
