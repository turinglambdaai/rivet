# Production signing

Rivet keeps development packaging and production trust credentials deliberately separate.

- `raco rivet package` creates the normal self-contained development distributable. macOS uses ad-hoc signing so the bundle can be validated locally.
- `raco rivet package --production` requires real platform signing credentials. Windows is Authenticode-signed and RFC 3161 timestamped. macOS is Developer ID signed, submitted to Apple notarization, stapled, and then production-verified.
- `raco rivet verify --production` re-checks the platform production trust requirements on an existing artifact.

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

## CI secrets

Production signing should run in a separate trusted release job or environment, not in pull-request CI.

Inject the environment variables above through the CI secret store. Do not commit PFX files or Apple private keys to the repository. If a PFX is provided as an encoded CI secret, materialize it only into the runner's temporary directory and point `RIVET_WINDOWS_SIGN_PFX` there.

For macOS, provision the Developer ID certificate/keychain and `notarytool` profile on the trusted runner before invoking `raco rivet package --production`.

The normal Rivet CI intentionally exercises only development packaging. It verifies that the production credential parser rejects incomplete or ambiguous configuration, while actual certificate-backed signing requires credentials owned by the publisher.
