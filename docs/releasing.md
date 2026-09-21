# Releasing Rivet

Rivet releases are tag-driven. The repository package version lives in `info.rkt`, and every released version must have a matching `CHANGELOG.md` section.

## Release checklist

1. Merge the release changes into `main`.
2. Confirm the `CI` and `Embedded Roundtrip` workflows are green on `main`.
3. Confirm `info.rkt` contains the intended semantic version and `CHANGELOG.md` contains the matching `## MAJOR.MINOR.PATCH` section.
4. Create and push an annotated tag named `vMAJOR.MINOR.PATCH`, for example `v0.2.0`.
5. The `Release` workflow validates the tag/version/changelog relationship, reruns the Racket test suite and CLI smoke check, builds a source package with `raco pkg create`, writes a SHA-256 checksum, and publishes both files in a GitHub Release.

Do not move or reuse an existing release tag. If a published release is wrong, fix the repository and publish a new patch version.

## Current release artifact

The framework release artifact is the Racket source package (`rivet-MAJOR.MINOR.PATCH.zip`) plus its SHA-256 file. GitHub also exposes its normal source archives for the tag.

The Windows and macOS application packaging commands are already smoke-tested in CI, but Rivet does not yet publish pre-signed commercial application installers as framework release artifacts. Production Windows signing and macOS Developer ID signing/notarization should be added as a separate release pipeline with repository/environment secrets and explicit certificate ownership.
