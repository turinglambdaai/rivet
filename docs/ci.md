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
- Linux: `ubuntu-24.04` with GTK 4.10+ development files and an embeddable Racket
  CS runtime.

`raco rivet build` is the required host-compilation gate. Add `package` and
`verify` when the job should also validate the distributable layout. Publisher
certificates and notarization credentials do not belong in pull-request CI;
use development packaging there and reserve `--production` for a protected
release environment.

Every maintained product should also commit `rivet-acceptance.rktd` and run
`raco rivet acceptance --json` in each native platform job. That manifest is
the executable definition of done: RackUnit, generated-client bridge tests,
native accessibility drivers, and packaged-product checks remain implemented
by their owning layer, while Rivet rejects missing declared coverage, timeouts,
nonzero exits, and missing evidence. Archive the JSON report on failure. See
[product acceptance evidence](product-acceptance.md).

## Copy-paste GitHub Actions workflow

The following workflow pins Rivet 0.11.0. Update every Rivet package source and
the Linux setup action to the same tag (or full commit) in one review. A direct
Git source is intentional: the Racket Package Catalog has one current entry
for a package name and cannot select an older Rivet release.

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
      - run: raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.12.0'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-windows
          path: acceptance-report.json
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
      - run: raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.12.0'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-macos
          path: acceptance-report.json
      - run: raco rivet build

  linux-host:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - name: Set up embeddable Racket CS
        uses: turinglambdaai/rivet/.github/actions/setup-embed-racket@v0.12.0
      - name: Install GTK4 development files
        run: |
          sudo apt-get update
          sudo apt-get install --yes libgtk-4-dev
      - name: Install the matching Rivet package and dependencies
        run: raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.12.0'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-linux
          path: acceptance-report.json
      - run: raco rivet build
```

Each job writes its `acceptance --json` report to a file and archives it as
`acceptance-report-<platform>` with `if: always()`, so a red leg still hands
over its evidence. Those names are exactly what
[`raco rivet verify-remote`](product-acceptance.md#orchestrate-remote-verification-from-one-host)
expects: from any editing host it dispatches the legs, waits for the runs,
downloads the archived reports, and folds them into the verification matrix.

The Linux order is load-bearing: install the Rivet package **after**
`setup-embed-racket`. The action's minimal Racket build intentionally ships
without packages; installing Rivet afterward resolves `cext-lib`, `crypto-lib`,
`keel`, and the rest of the dependency closure into the package directory that
the embeddable runtime actually uses. Installing Rivet earlier under a full
Racket distribution can make those dependencies appear satisfied there while
leaving the minimal runtime incomplete; a later backend bundle then fails, for
example because `raco ctool` is supplied by `cext-lib`.

For an intentionally moving development channel, replace the direct Git source
with the catalog name `rivet` and use the setup action from `@main`. Do not use
that pair as a release pin: catalog installation follows the catalog's current
checksum and there is no `raco pkg install rivet@<version>` selector. The
standard hold-back form is the tag-pinned Git source shown above. Racket treats
the fragment as the Git revision while retaining normal dependency resolution.

Never leave the fragment empty. `...rivet.git#` with a bare `#` does not fail
the install: Racket resolves it to the default branch, so CI compiles against
moving `main` while the workflow believed it was pinned — an undefined
workflow variable has shipped releases built this way. Always pin a tag or a
commit SHA after `#`, and run `raco rivet doctor --release` before publishing;
the release gate fails on empty refs, on tag refs that do not match the
installed rivet release, on stale generated files, and on host source that
calls the update API with keywords the installed rivet does not accept.

Rivet itself additionally launches the generated GTK4 package inside a
headless Weston compositor with `GDK_BACKEND=wayland`. This is a native
Wayland gate: `DISPLAY` is unset, so the application cannot silently pass by
using X11 or XWayland. Products supporting Linux should keep an equivalent
Wayland launch in their release matrix; see [Linux display policy](linux-display.md).

Rivet's own Ubuntu jobs run provisioning `apt-get` commands through
`.github/scripts/apt-retry.sh`. Each attempt is non-interactive, applies APT's
network and lock retries, and has a three-minute wall-clock limit; one fresh
attempt is allowed before the job fails. Product CI should use the same bounded
principle so a stalled package mirror cannot consume the whole native-build
budget. Package installation lifecycle tests themselves stay unwrapped because
their raw transaction outcome is the behavior under test.

The separate `Native UI End-to-End` workflow packages the maintained Taskboard
and drives its real WinUI 3, SwiftUI/AppKit, and GTK4 accessibility surfaces.
It covers activation, an RPC mutation, an Event, State rendering, and orderly
close while retaining bounded failure evidence. See
[native UI end-to-end testing](native-ui-testing.md) for the application-level
extension contract.

For a security-sensitive product, replace the action tag with the full commit
SHA for that tag and use the same commit in the package URL fragment. The action downloads the official minimal
Racket CS source archive, verifies its SHA-256, builds and caches the static
embedding runtime by version/OS/architecture, and exports
`RIVET_RACKET_INCLUDE`, `RIVET_RACKET_LIB_DIR`, `RIVET_RACKET_LIBRARY`, and
`RIVET_RACKET_BOOT_DIR`. Product workflows should not copy those discovery
rules.

For local Rivet development, a linked checkout remains appropriate. Pin that
checkout and the setup action to the same revision in CI. A host compiled
against one Rivet revision and released with another is not a useful gate.

## Release gate

Before pushing a tag, require all native-host jobs above and the product's
Racket tests. The protected release job can then add production packaging,
signing, notarization, update-manifest signing, and artifact publication. It
should not be the first job that invokes the native compiler.

If the release workflow intentionally pins an older runner or Xcode image,
keep that exact image in the pull-request matrix until the release environment
is upgraded. Runner labels can change over time; parity with the product's
actual release workflow is the contract.
