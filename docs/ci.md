# Continuous integration

Every first-party native host must compile in pull-request CI. A Racket-only
test job, schema check, or package dry run does not prove that WinUI, SwiftUI,
or GTK source still compiles. Waiting for a tagged release to perform the first
native compilation turns ordinary compiler errors into release incidents.

Use the same runner image class and toolchain family in CI that the release job
uses:

- Windows: `windows-latest` for the WinUI 3 host;
- macOS: both `macos-latest` and `macos-15`, so current Swift and the pinned
  Xcode 16 release environment both compile the SwiftUI/AppKit host;
- Linux: `ubuntu-latest` with GTK4 development files and an embeddable Racket
  CS runtime.

`raco rivet build` is the required host-compilation gate. Add `package` and
`verify` when the job should also validate the distributable layout. Publisher
certificates and notarization credentials do not belong in pull-request CI;
use development packaging there and reserve `--production` for a protected
release environment.

## Copy-paste GitHub Actions workflow

The following workflow assumes the application installs the released `rivet`
package from the Racket Package Catalog. Pin the Racket and Rivet versions used
by production instead of allowing the two workflows to drift.

```yaml
name: Native hosts

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  windows-host:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          architecture: x64
          distribution: full
          variant: CS
          version: '9.3'
      - run: raco pkg install --auto --no-docs rivet
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet build

  macos-host:
    strategy:
      fail-fast: false
      matrix:
        runner: [macos-latest, macos-15]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          architecture: x64
          distribution: full
          variant: CS
          version: '9.3'
      - run: raco pkg install --auto --no-docs rivet
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet build

  linux-host:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Set up embeddable Racket CS
        uses: turinglambdaai/rivet/.github/actions/setup-embed-racket@main
      - name: Install GTK4 development files
        run: |
          sudo apt-get update
          sudo apt-get install --yes libgtk-4-dev
      - run: raco pkg install --auto --no-docs rivet
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet build
```

For a security-sensitive product, replace `@main` with the Rivet tag or full
commit SHA used by the application. The action downloads the official minimal
Racket CS source archive, verifies its SHA-256, builds and caches the static
embedding runtime by version/OS/architecture, and exports
`RIVET_RACKET_INCLUDE`, `RIVET_RACKET_LIB_DIR`, `RIVET_RACKET_LIBRARY`, and
`RIVET_RACKET_BOOT_DIR`. Product workflows should not copy those discovery
rules.

If an application installs Rivet from a linked or Git checkout rather than the
catalog, pin that checkout and the setup action to the same revision. A host
compiled against one Rivet revision and released with another is not a useful
gate.

## Release gate

Before pushing a tag, require all native-host jobs above and the product's
Racket tests. The protected release job can then add production packaging,
signing, notarization, update-manifest signing, and artifact publication. It
should not be the first job that invokes the native compiler.

If the release workflow intentionally pins an older runner or Xcode image,
keep that exact image in the pull-request matrix until the release environment
is upgraded. Runner labels can change over time; parity with the product's
actual release workflow is the contract.
