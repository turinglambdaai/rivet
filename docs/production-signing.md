# Production signing

Rivet keeps development packaging and production trust credentials deliberately separate.

- `raco rivet package` creates the normal self-contained development distributable. macOS uses ad-hoc signing so the bundle can be validated locally.
- `raco rivet package --production` requires real platform signing credentials. Windows is Authenticode-signed and RFC 3161 timestamped. macOS is Developer ID signed, submitted to Apple notarization, stapled, and then production-verified. On Linux, production packaging is `raco rivet release`: the final installer is signed with a detached Ed25519 signature instead of OS-level code signing.
- `raco rivet verify --production` re-checks the platform production trust requirements on an existing artifact. On Linux this re-derives the installer archive from the package directory and validates its Ed25519 signature.

Rivet does not store certificate passwords, private keys, Apple credentials, or notary credentials in `rivet.rktd`.

## Windows

Production Windows packaging requires the Windows SDK `signtool.exe`. `raco rivet doctor` reports whether it was discovered.

Choose exactly one signing identity mode.

### Certificate store

Set:

- `RIVET_WINDOWS_SIGN_CERT_SHA1` — SHA-1 thumbprint of the code-signing certificate available to the current Windows account.
- `RIVET_WINDOWS_TIMESTAMP_URL` — RFC 3161 timestamp service URL.

The certificate private key remains in the Windows certificate store or its hardware-backed provider.

### PFX

Set:

- `RIVET_WINDOWS_SIGN_PFX` — path to the PFX/P12 code-signing certificate.
- `RIVET_WINDOWS_SIGN_PFX_PASSWORD` — PFX password. The variable must be present; an explicitly empty password is allowed.
- `RIVET_WINDOWS_TIMESTAMP_URL` — RFC 3161 timestamp service URL.

Rivet passes the PFX password to `signtool` but deliberately omits the signing argv from error diagnostics so a failed signing command does not echo the secret.

Production packaging signs Rivet's `RivetHost.exe`. Bundled Racket and Windows App SDK DLLs remain byte-for-byte upstream artifacts instead of being re-signed with the application certificate.

After signing, Rivet runs the normal DLL dependency audit and `signtool verify /pa /v` on the executable.

## macOS

Production macOS packaging requires a Developer ID Application certificate installed in the active keychain and a `notarytool` keychain profile.

Set:

- `RIVET_MACOS_SIGN_IDENTITY` — the Developer ID Application identity passed to `codesign`.
- `RIVET_MACOS_NOTARY_PROFILE` — the keychain profile name passed to `xcrun notarytool --keychain-profile`.

Create the notary profile outside the repository with Apple's `notarytool store-credentials` flow. The profile may be backed by an App Store Connect API key or Apple ID credentials; Rivet only receives the profile name.

Production packaging performs these steps:

1. Sign the embedded `Racket.framework` with hardened runtime and a secure timestamp.
2. Sign the outer `.app` with the same identity, hardened runtime, secure timestamp, and Rivet entitlements.
3. Create a temporary notarization ZIP under `.rivet/notary/`.
4. Submit it with `xcrun notarytool submit --wait`.
5. Staple the accepted ticket to the `.app`.
6. Run normal package verification plus `xcrun stapler validate` and Gatekeeper `spctl --assess`.

The temporary notarization ZIP is a build artifact, not a credential store.

## Linux

Linux has no OS-level code-signing gate, so Rivet defines production trust at the installer level and reuses the distribution layer's audited Ed25519 primitives:

- `raco rivet release` packs the verified self-contained package into a deterministic `.tar.gz` (sorted ustar entries, epoch timestamps, root ownership, timestamp-free gzip) and writes a detached Ed25519 signature beside it as `<installer>.sig` (base64).
- The same deterministic archive makes verification strong: `raco rivet verify --production` rebuilds the archive from the packaged directory, requires a byte-identical match with the released installer, and validates the detached signature with the configured public key.

Set:

- `RIVET_LINUX_SIGN_PRIVATE_KEY` — path to a DER-encoded Ed25519 private key used to sign the installer.
- `RIVET_LINUX_SIGN_KEY_ID` — public identifier for the signing key.
- `RIVET_LINUX_SIGN_PUBLIC_KEY` — path to the matching DER-encoded public key, required by `raco rivet verify --production`.

Generate the key pair outside the repository with the same openssl flow as the update key. Distro-native packages (`.deb`/`.rpm`, AppImage, apt repository GPG trust) remain follow-up work; the signed self-contained tarball is the current production artifact.

## CI secrets

Production signing should run in a separate trusted release job or environment, not in pull-request CI.

Inject the environment variables above through the CI secret store. Do not commit PFX files or Apple private keys to the repository. If a PFX is provided as an encoded CI secret, materialize it only into the runner's temporary directory and point `RIVET_WINDOWS_SIGN_PFX` there.

For macOS, provision the Developer ID certificate/keychain and `notarytool` profile on the trusted runner before invoking `raco rivet package --production`.

The normal Rivet CI intentionally exercises only development packaging. It verifies that the production credential parser rejects incomplete or ambiguous configuration, while actual certificate-backed signing requires credentials owned by the publisher.

## Update content signing

Online updates use a separate Ed25519 key; Authenticode, Developer ID, notarization, and HTTPS are additional layers rather than substitutes. Set `RIVET_UPDATE_PRIVATE_KEY` to a DER-encoded private key path and `RIVET_UPDATE_KEY_ID` to its public identifier only in the trusted release environment. The public key is embedded by the application, while the private key must never enter the source tree or ordinary pull-request CI.

`raco rivet release` signs the contained application and final installer with the platform identity (Authenticode, Developer ID, or the Linux Ed25519 artifact key), then signs the update manifest payload with Ed25519. Products with no update channel use `raco rivet release --without-updates`; platform signing, installer verification, SBOM, and notices remain unchanged while only the update-manifest stage is omitted. See [Release and updates](release-and-updates.md) for rotation and rollback policy.
