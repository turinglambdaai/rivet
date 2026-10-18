# Product acceptance evidence

`raco rivet acceptance` turns a product's definition of done into an
executable, source-controlled contract. It complements RackUnit and each
platform's native UI tools; it does not replace them or introduce a shared UI
selector language.

The command reads `rivet-acceptance.rktd`, validates that every declared
requirement has a suite on every required platform, then runs the suites for
the current host. Each command is launched as an executable plus argv without
a shell. Rivet enforces a timeout, drains stdout and stderr concurrently,
captures at most 64 KiB from each stream, checks the exit status, and verifies
declared evidence paths before reporting success.

## Manifest

Commit the manifest at the project root:

```racket
#hasheq(
 (version . 1)
 (requirements
  . (#hasheq((kind . contract) (platforms . (windows macos linux)))
     #hasheq((kind . native-ui) (platforms . (windows)))))
 (suites
  . (#hasheq((id . core)
             (kind . contract)
             (platforms . (windows macos linux))
             (command . ("raco" "test" "racket/"))
             (timeout-seconds . 300))
     #hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/e2e/windows.ps1"))
             (timeout-seconds . 900)
             (evidence . (".rivet/acceptance/windows/trace.json"
                          ".rivet/acceptance/windows/accessibility.json"))))))
```

The supported suite kinds are:

- `unit`: isolated implementation tests;
- `contract`: product behavior, schema, golden output, and real storage;
- `bridge`: generated client through RVT1 to the embedded backend;
- `native-build`: compilation of the first-party platform host;
- `native-ui`: accessibility-driven interaction with the native product;
- `package`: behavior or structure of the distributable artifact; and
- `release`: installer, update, rollback, signing, or production trust.

Suite ids are unique symbols. Platforms are a non-empty subset of `windows`,
`macos`, and `linux`. A command is a non-empty list of argv strings; shell
syntax, redirection, pipes, and command interpolation are not interpreted.
Timeouts are positive integers capped at two hours. Evidence entries are file
paths below `.rivet/acceptance/`. Rivet removes each declared file before the
suite starts and then requires the suite to recreate it, so a stale artifact
from an earlier green run cannot satisfy the current run. `native-ui`,
`package`, and `release` suites must declare at least one evidence file.

`requirements` is the reviewable policy. For every kind/platform pair there
must be at least one matching suite or the manifest is rejected before a child
process starts. Product owners should protect changes to requirements, CI,
golden data, and native UI drivers with the same review rules as public API
changes. A green result is not meaningful if a change weakens the evidence
contract in the same patch without explicit review.

## CI usage

Run the command in every native host job, not only on Linux:

```bash
raco rivet acceptance --json
```

The JSON report contains the project, platform, manifest path, configured
requirements, selected suites, bounded output, duration, timeout state, exit
code, and missing evidence. Archive it even when the job fails. Use `--suite
<id>` only for diagnosis; the required merge gate should run the complete
current-platform set.

For an alternative manifest during migration:

```bash
raco rivet acceptance --manifest path/to/acceptance.rktd --json
```

Before editing an existing checkout, first inspect the worktree, fetch the
tracked remote, and update with fast-forward-only semantics. Record the base
commit with the acceptance report. A dirty, diverged, or unreachable checkout
is a reason to stop and report the state, not a reason to stash, reset, or
claim evidence against an unknown base.

## What counts as complete

RackUnit is the normal owner of shared Racket behavior. A product that claims
the Rivet architecture should additionally exercise at least one real
generated-client/embedded-backend round trip and one critical packaged native
UI flow per supported desktop platform. The native UI driver should assert
semantic roles, one RPC mutation, resulting State/Event presentation, and
orderly shutdown. See [native UI end-to-end testing](native-ui-testing.md).

Fixed sleeps, process-survival-only smoke tests, mock-only backend calls, or a
CLI substitute for a GUI action are useful diagnostics but are not evidence
for the corresponding product behavior. Prefer bounded waits on observable
state and disposable HOME/config/database roots. Never modify a developer's
real profile or kill unrelated processes from an acceptance suite.

An agent may choose an implementation. It may not reinterpret completion: a
required suite that was skipped, not run on its declared platform, timed out,
used the wrong artifact, or failed to produce its evidence means the work is
not complete.
