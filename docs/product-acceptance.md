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
             (evidence
              . (#hasheq((path . ".rivet/acceptance/windows/accessibility.json")
                         (kind . accessibility-snapshot))
                 #hasheq((path . ".rivet/acceptance/windows/screen.png")
                         (kind . screenshot))
                 ".rivet/acceptance/windows/trace.json"))))))
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
Every suite command runs with the project root as its current directory, so
paths in a suite command are relative to the project.
Timeouts are positive integers capped at two hours. Evidence entries are file
paths below `.rivet/acceptance/`. Rivet removes each declared file before the
suite starts and then requires the suite to recreate it, so a stale artifact
from an earlier green run cannot satisfy the current run. `native-ui`,
`package`, and `release` suites must declare at least one evidence file.

Evidence entries are classified so remote consumers know what a green suite
actually produced. A bare path string means the `generic` kind; a hash declares
`path` and one `kind` of `accessibility-snapshot`, `screenshot`,
`interaction-trace`, `log`, or `generic`. Accessibility snapshots are the
primary cross-platform record — semantic UI state that is comparable across
platforms — while screenshots are supplemental because native presentations
are expected to differ. The `--json` report pins every declared entry's kind,
presence, byte size, and SHA-256, so an archived report audits the artifacts
it vouches for.

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

Validate a manifest without running anything first — a hand-edited
`rivet-acceptance.rktd` with a syntax error should fail in seconds, not
minutes into a packaged suite:

```bash
raco rivet acceptance --dry-run
```

The dry run loads and validates the manifest (shape, requirement coverage),
resolves the current platform's suites and their executables, checks the
evidence path rules, and exits before launching any child. Its report is
flagged `"dry-run": true` with per-suite `"dry-run"` statuses; it is a
validation record, not acceptance evidence, and must not feed `raco rivet
matrix` as a platform leg.

For an alternative manifest during migration:

```bash
raco rivet acceptance --manifest path/to/acceptance.rktd --json
```

Before editing an existing checkout, first inspect the worktree, fetch the
tracked remote, and update with fast-forward-only semantics. Record the base
commit with the acceptance report. A dirty, diverged, or unreachable checkout
is a reason to stop and report the state, not a reason to stash, reset, or
claim evidence against an unknown base.

## Drive the embedded backend in-process

Contract suites need the backend's real behavior, not mocks. A backend is an
ordinary Racket module: requiring it runs the `define-*` declarations, and
`serve` from `rivet/backend` speaks RVT1 over any binary ports, so one test
process can exercise a real embedded-backend round trip:

1. Instantiate the backend module under test (declarations register when the
   module is instantiated). A test that needs a "restarted" backend must
   re-instantiate the module under a fresh namespace, take `serve` (and any
   `record-ref`) from that same namespace, and require the module by file
   path — a quoted symbol resolves only in the namespace that already knows it:

   ```racket
   (define ns (make-base-empty-namespace))
   (parameterize ([current-namespace ns])
     (namespace-require/copy `(file ,(path->string backend-path))))
   (define serve-proc
     (parameterize ([current-namespace ns]) (eval #'serve)))
   ```
2. Build a pipe pair, run `(serve in out)` on a thread under a custodian, and
   remember that `serve` blocks until the session ends; closing the client's
   output port ends it.
3. The backend writes the hello frame at startup, before it reads anything,
   so the first `read-frame` on the client side observes it.
4. Speak RVT1 with `rivet/protocol`, which publicly exports the full testing
   surface: `protocol-version`, the `frame` struct and its accessors,
   `message:hello`, `message:request`, `message:response`, `message:error`,
   `message:event`, `message:cancel`, `message:shutdown`, `write-frame`,
   `read-frame`, `encode-value`, `decode-value`, and the limit constants.
   There is no separate in-process RPC entry point — the protocol boundary is
   the contract under test.
5. Assert wire-visible outcomes: the response payload for an accepted call,
   an error frame for a rejected input (its payload is an encoded String
   value), and the reserved `$state` Event that a State mutation emits before
   the response frame.

```racket
(require rivet/backend
         rivet/protocol)

;; Instantiate the backend module under test (declarations register here).
(dynamic-require (build-path (current-directory) "backend.rkt") #f)

(define-values (backend-in client-out) (make-pipe))
(define-values (client-in backend-out) (make-pipe))
(define server (thread (lambda () (serve backend-in backend-out))))

;; The backend writes the hello frame before reading anything.
(define hello (read-frame client-in))
(unless (eq? (frame-type hello) message:hello)
  (error 'check "expected hello, got ~a" (frame-type hello)))

(write-frame (frame message:request 1
                    (encode-value (list "bump" 41)))
             client-out)
;; A State mutation inside the RPC emits the reserved $state event before
;; the response frame; a rejected input arrives as an error frame instead.
(define state-event (read-frame client-in))
(unless (and (eq? (frame-type state-event) message:event)
             (equal? (decode-value (frame-payload state-event))
                     (list "$state" (list "counter" 41))))
  (error 'check "unexpected $state event: ~e" state-event))
(define response (read-frame client-in))
(define result (decode-value (frame-payload response)))
(unless (equal? result 41)
  (error 'check "expected 41, got ~e" result))

(close-output-port client-out)
(thread-wait server)
```

Pair this with unit tests for pure logic and with the native-ui suites below;
the three together are what "real storage and real protocol boundary" means
for a contract requirement.

## Classify desktop capabilities

Not every desktop capability carries the same parity obligation. Declare each
one as one of three categories and let the category drive the requirements
list:

- **Guaranteed** — the same semantics are required on every declared desktop
  platform; a missing platform is a release failure. These become
  `requirements` entries with all desktop platforms and suites of the matching
  kinds.
- **Conditional capability** — the same API and semantics everywhere, but
  runtime availability may differ: tray, global shortcuts, secure storage,
  notifications. The adapter must report supported/unavailable/permission
  state explicitly instead of failing silently, and suites assert the
  reported state, not unconditional success.
- **Platform-specific** — intentionally native-only behavior with no forced
  cross-platform abstraction. It is excluded from the requirements list;
  platform-specific does not mean unverified, it means verified by that
  platform's own suites.

The goal is semantic parity, not identical visual behavior. Native SwiftUI,
WinUI, and GTK presentations are expected to differ; the acceptance evidence
(accessibility state, RPC effects, declared artifacts) must not.

A Guaranteed feature is not complete until every declared platform has run
its suites — which is what the matrix below proves.

## Aggregate the cross-platform matrix

The local operating system is an editing environment, not the boundary of
verification. Each platform leg archives its acceptance report as a CI
artifact; the matrix folds the reports for one commit into a single verdict:

```bash
raco rivet matrix windows-report.json macos-report.json linux-report.json
raco rivet matrix windows-report.json --json
```

```text
Rivet verification matrix: Taskly - 3 reports

  requirement    windows     macos     linux
  contract          PASS      PASS      PASS
  native-ui         PASS      PASS      FAIL

Cross-platform status: FAIL
```

The rules are deterministic: a cell is proven only by a passing suite of that
kind in a report from that platform; ran-but-failed evidence fails the cell;
no evidence for a platform means missing, never silently green. All reports
must describe the same project, so one product's green leg cannot vouch for
another. A diagnostic `--suite` run is accepted and flagged as partial in the
matrix, but merge gates should feed complete reports. The exit code is green
only when every required kind/platform cell is proven.

Feed the reports for the commit under verification; the matrix aggregates
what it is given and does not heuristically prefer fresher runs.

## Orchestrate remote verification from one host

`raco rivet verify-remote` closes the loop for an agent editing away from the
platform legs: it dispatches each platform's acceptance leg on GitHub Actions,
waits for the runs, downloads the archived `acceptance --json` reports, and
folds them into the matrix:

```bash
raco rivet verify-remote --repo OWNER/REPO --ref <branch-or-sha>
raco rivet verify-remote --repo OWNER/REPO --ref <sha> --platform linux
raco rivet verify-remote --repo OWNER/REPO --ref <sha> --json
```

The command drives the `gh` CLI and nothing else. The defaults encode one
convention — workflow `verify.yml`, artifacts named
`acceptance-report-<platform>` — and `--workflow`/`--artifact-prefix` adapt it
to a product's own naming. The workflow contract is: a `workflow_dispatch`
trigger with a `platform` input (`linux`, `windows`, or `macos`), one
`raco rivet acceptance --json` per leg, and the report uploaded with
`if: always()` so a red leg still hands over its evidence. Re-running only the
affected platform is just `--platform <name>`; the final verdict still needs
every required platform's report, because missing platforms are never silently
green.

The command exits green only when the matrix passes and every requested
platform delivered a report. Run collections land under
`.rivet/verify-remote/` (adjust with `--output-directory`), and `--json` adds
the per-run conclusions and report paths to the matrix document.

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
