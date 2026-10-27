# Native UI end-to-end testing

Rivet keeps UI tests native for the same reason it keeps production UI native:
the platform accessibility and interaction stacks are part of the product.
The reference Taskboard is exercised through UI Automation on Windows,
AXUIElement on macOS, and AT-SPI on Linux. No shared widget DSL or synthetic
Rivet view tree sits between the test and WinUI 3, SwiftUI/AppKit, or GTK4.

## Behavioral contract

The `Native UI End-to-End` workflow packages the application before testing it
and requires each platform driver to prove all of the following:

1. a real native window can be discovered and activated;
2. stable semantic names/identifiers and roles are exposed;
3. invoking `new-task` crosses the generated client and RVT1 boundary and the
   resulting State reaches the native list;
4. invoking `generate-demo` makes an `operation-progress` Event visible through
   the native accessibility surface;
5. the final 1,000-row State reaches the UI; and
6. the orderly backend shutdown runs to completion. On macOS the quit Apple
   Event (what Cmd+Q delivers) is the reliable trigger for a packaged app —
   signals and close-button presses are not; see the launch notes below.

Every run uploads the bounded interaction trace and accessibility snapshots.
It also captures a screen image when the runner supports the platform capture
API, plus application/compositor logs on Linux. The evidence is uploaded with
`if: always()` so a failed assertion remains diagnosable.

## Application extension point

Product applications own their views, so they also own the identifiers and
scenario vocabulary. Keep those identifiers in native source:

- WinUI: `AutomationProperties.AutomationId` and
  `AutomationProperties.Name`;
- SwiftUI/AppKit: `.accessibilityIdentifier`, labels, and native roles; and
- GTK4: `GtkAccessible` properties and meaningful widget roles.

Copy the matching driver under `rivet/tests/native-ui/`, replace the reference
identifiers and actions with one product-critical scenario, and add the driver
to a packaging job. Declare that driver as a `native-ui` suite in the
product's `rivet-acceptance.rktd` so missing platform coverage fails before the
job starts; see [product acceptance evidence](product-acceptance.md). A useful
minimum scenario has one RPC-driven mutation, one
Event, a stable accessibility-tree assertion, and orderly close. Test-only
protocol messages and a cross-platform selector language are deliberately not
extension points.

## Launching the packaged application on macOS

The macOS driver receives the application's process id (`--pid`) and an
evidence output directory (`--output`); the suite command owns launching and
reaping the application around it. A proven shape for that runner:

1. `raco rivet package` produces the development distributable; locate the
   newest bundle under `dist/` and its executable with
   `plutil -extract CFBundleExecutable raw` on the bundle's `Info.plist`.
   By default `package` also launches the artifact once as a launch smoke —
   pass `--skip-launch-smoke` when the suite itself owns launching, so the
   run stays hermetic.
2. Launch the executable in the background with a disposable data root in the
   environment (the application's own override hook — never the developer's
   real profile), and take `$!` as the pid for the driver.
3. Reap the application through its quit Apple Event after the driver
   finishes (send `osascript -e 'tell application id "..." to quit'` or post
   Cmd+Q through the event path), then poll `kill -0`; run a second launch
   against the same data root to assert persisted effects. Do not rely on
   `SIGTERM`, programmatic termination, or the window close button for a
   packaged app: on current macOS they can all be swallowed while the main
   thread idles, and only the quit Apple Event reliably runs the orderly
   shutdown. Never drive keyboard phases in a second instance of the same
   app: it can report a false-positive `frontmost` while keyboard event
   routing is entirely broken (not even clicking the title bar recovers it).
4. Compile the Swift driver with `swiftc` (or precompile it in the suite
   directory); the driver requires the process to hold Accessibility trust,
   so CI runners must grant it to the test host.

A rare embedded-runtime startup race can leave a launched instance wedged:
the backend answers the handshake but the window never renders while dozens
of runtime threads spin at full CPU. The signature is cheap to detect from
the driver (`ps -o %cpu=` on the pid staying at several hundred percent
beyond the ready window with no AX window), and one bounded relaunch of a
fresh instance is the proven mitigation — the payback and regexmate suites
both ship it. Report a wedge with its diagnostic bundle (process sample,
spin signature, app log) as a runtime defect rather than retrying forever;
a wedged instance never self-heals and must be killed by exact pid.

The reference macOS AX driver now records a bounded `ps` snapshot into
`startup-spin-process.txt` if a **CI** run times out before finding its
first native window. If that exact test PID remains above 200% CPU, it also
attempts `sample PID 3 -file startup-spin.sample.txt` for a three-second
native thread stack sample; permission errors are recorded but do not hide
the original AX failure. The existing `if: always()` CI artifact uploads
include these files only when captured. Do not infer a Chez GC deadlock from
the CPU signature alone: the stack evidence must be inspected before
modifying the runtime. A developer's local run does not automatically sample
a potentially sensitive process; CI evidence may contain host stack paths and
is governed by repository CI retention/access controls.

## Driving keyboards and focus on macOS

The reference driver's helpers exist for the real event path — `focus`,
`typeText`, `postKey` (Return is keycode 36, Escape is 53) — because a text
field driven only through `AXUIElementSetValue` skips what the user actually
exercises. Four desktop realities the recipe must respect, each of which
fails silently without them:

1. **A successful AX focus write is not focus.** Setting
   `kAXFocusedAttribute` can report success while the field editor never
   starts — SwiftUI toolbar items and NSView representables have no key-view
   loop of their own. After focusing, verify the focus actually moved (read
   back `kAXFocusedAttribute` *and* confirm the typed text lands, or assert
   the app's first responder); products hosting such fields should provide an
   explicit key-view loop (see the regexmate key-view fix for the pattern).
2. **Input methods swallow synthetic text.** A third-party IME (for example
   a pinyin IME) intercepts CGEvent unicode-string events, so composition
   never reaches the field — and non-unicode key events such as Escape can be
   swallowed too. Switch to an ASCII-capable input source with the TextInput
   Source APIs (`TISCopyCurrentKeyboardInputSource` /
   `TISSelectInputSource`) before typing and restore the original afterwards;
   the reference driver ships those TIS helpers for exactly this purpose.
3. **Posted keys go to whatever the user is using.** On a shared desktop,
   CGEvents route to the currently focused application. Verify the app under
   test is frontmost before every posted key and fail fast when it is not —
   a driver that types without that check can pour `Cmd+A` and `Delete` into
   a developer's editor. CI's exclusive runners are the default venue for
   keyboard phases for exactly this reason.
4. **AX elements die with their views.** Passing through an empty state can
   recreate a table and leave previously captured `AXUIElement` references
   as zombies — attributes return stale or empty values while the app
   visibly works. Re-find elements from the live AX tree inside every
   bounded wait; never cache element references across scenario steps that
   can mutate the view structure.

Fixed sleeps are not a substitute for the bounded `waitFor` probes.

Keep snapshots small: cap recursion depth, record semantic fields rather than
platform object dumps, and never include user data or secret values. Failure
artifacts should be retained only as long as the repository's normal CI logs.
