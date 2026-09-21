# Releasing Rivet

Rivet framework releases are tag-driven. The repository package version lives in `info.rkt`, and every released version must have a matching `CHANGELOG.md` section.

## Framework release checklist

1. Merge the release changes into `main`.
2. Confirm the `CI` and `Embedded Roundtrip` workflows are green on `main`.
3. Confirm `info.rkt` contains the intended semantic version and `CHANGELOG.md` contains the matching `## MAJOR.MINOR.PATCH` section.
4. Create and push an annotated tag named `vMAJOR.MINOR.PATCH`, for example `v0.2.0`.
5. The `Release` workflow validates the tag/version/changelog relationship, reruns the Racket test suite and CLI smoke check, builds a source package with `raco pkg create`, writes a SHA-256 checksum, and publishes both files in a GitHub Release.

Do not move or reuse an existing release tag. If a published release is wrong, fix the repository and publish a new patch version.

## Current framework release artifact

The framework release artifact is the Racket source package (`rivet-MAJOR.MINOR.PATCH.zip`) plus its SHA-256 file. GitHub also exposes its normal source archives for the tag.

The tag-driven framework Release workflow intentionally does not own application-publisher certificates. That keeps Rivet framework releases reproducible without coupling the repository to one developer's Windows or Apple identity.

## Shipping an application built with Rivet

Application publishers can create trusted production packages with:

```text
raco rivet package --production
raco rivet verify --production
```

On Windows, production mode requires Authenticode credentials and an RFC 3161 timestamp service. On macOS, it requires a Developer ID Application identity and a configured `notarytool` keychain profile; Rivet signs, notarizes, staples, and Gatekeeper-validates the application.

The production credentials are injected from the local machine or trusted CI environment. They are not stored in `rivet.rktd` or the repository. See `docs/production-signing.md` for the environment-variable contract and recommended CI separation.

A future Rivet framework release pipeline may publish example signed applications or installer formats, but those artifacts must use publisher-owned secrets in an explicitly trusted release environment rather than ordinary pull-request CI.
