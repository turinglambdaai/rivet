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
6. native window close or `SIGTERM` completes the orderly backend shutdown.

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
2. Launch the executable in the background with a disposable data root in the
   environment (the application's own override hook — never the developer's
   real profile), and take `$!` as the pid for the driver.
3. Poll `kill -0` for an orderly exit after the driver finishes, then run a
   second launch against the same data root to assert persisted effects.
4. Compile the Swift driver with `swiftc` (or precompile it in the suite
   directory); the driver requires the process to hold Accessibility trust,
   so CI runners must grant it to the test host.

Keep the scenario's keyboard path real: `focus` (asserting
`kAXFocusedAttribute`), `typeText` (CGEvent unicode-string events), and
`postKey` (Return is keycode 36, Escape is 53) are part of the reference
driver for exactly this purpose — a text field driven only through
`AXUIElementSetValue` skips the event path the user actually exercises. Fixed
sleeps are not a substitute for the bounded `waitFor` probes.

Keep snapshots small: cap recursion depth, record semantic fields rather than
platform object dumps, and never include user data or secret values. Failure
artifacts should be retained only as long as the repository's normal CI logs.
