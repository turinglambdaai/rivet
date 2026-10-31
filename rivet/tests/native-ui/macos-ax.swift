import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct Options {
    let pid: pid_t
    let output: URL
}

enum DriverError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self { case .failure(let message): return message }
    }
}

func parseOptions() throws -> Options {
    var pid: pid_t?
    var output: URL?
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--pid":
            guard let value = iterator.next(), let number = Int32(value) else {
                throw DriverError.failure("--pid requires an integer")
            }
            pid = number
        case "--output":
            guard let value = iterator.next() else {
                throw DriverError.failure("--output requires a path")
            }
            output = URL(fileURLWithPath: value, isDirectory: true)
        default:
            throw DriverError.failure("unknown argument: \(argument)")
        }
    }
    guard let pid, let output else {
        throw DriverError.failure("usage: macos-ax --pid PID --output DIRECTORY")
    }
    return Options(pid: pid, output: output)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
    attribute(element, name) as? Bool ?? false
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func walk(_ element: AXUIElement) -> [AXUIElement] {
    [element] + children(element).flatMap(walk)
}

func find(_ root: AXUIElement, identifier: String) -> AXUIElement? {
    walk(root).first {
        stringAttribute($0, kAXIdentifierAttribute) == identifier
    }
}

func waitFor<T>(
    _ description: String,
    timeout: TimeInterval = 30,
    probe: () -> T?
) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = probe() { return value }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw DriverError.failure("timed out waiting for \(description)")
}

// Issue #329: capture the *real* wedged process on a CI launch failure.
// A successful backend handshake without an AX window can indicate a rare
// embedded Chez/Racket startup spin. Static stack guesses are not evidence.
// Only CI may capture a bounded sample, and only for the exact test PID.
func captureStartupSpinEvidence(pid: pid_t, output: URL) {
    guard ProcessInfo.processInfo.environment["CI"] == "true", pid > 0 else { return }
    func capture(_ executable: String, _ arguments: [String]) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    let ps = capture("/bin/ps", ["-p", String(pid), "-o", "pid=,ppid=,stat=,%cpu=,etime=,comm="])
    let report = ps?.1 ?? "ps failed or process already exited"
    try? report.write(to: output.appendingPathComponent("startup-spin-process.txt"),
                      atomically: true, encoding: .utf8)
    // Sampling a healthy but slow startup wastes time and can expose
    // unrelated runner activity. Only sample a high-CPU candidate.
    let cpuText = capture("/bin/ps", ["-p", String(pid), "-o", "%cpu="])?.1 ?? ""
    guard let cpu = Double(cpuText.trimmingCharacters(in: .whitespacesAndNewlines)),
          cpu >= 200 else { return }

    let file = output.appendingPathComponent("startup-spin.sample.txt")
    // 'sample PID DURATION -file PATH' is bounded to three seconds on macOS.
    // Permission denial is kept as separate evidence, never hides the AX
    // failure and never broadens sampling to other processes.
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    command.arguments = [String(pid), "3", "-file", file.path]
    let errors = Pipe()
    command.standardError = errors
    command.standardOutput = FileHandle.nullDevice
    if (try? command.run()) != nil {
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        if !errorData.isEmpty {
            try? errorData.write(to: output.appendingPathComponent("startup-spin-sample-stderr.txt"))
        }
    }
}

func snapshot(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
    var result: [String: Any] = [
        "role": stringAttribute(element, kAXRoleAttribute),
        "identifier": stringAttribute(element, kAXIdentifierAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "label": stringAttribute(element, kAXDescriptionAttribute),
        "value": stringAttribute(element, kAXValueAttribute),
    ]
    if depth < 8 {
        result["children"] = children(element).map { snapshot($0, depth: depth + 1) }
    }
    return result
}

func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func press(_ element: AXUIElement, description: String) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        throw DriverError.failure("AXPress failed for \(description): \(result.rawValue)")
    }
}

func setText(_ element: AXUIElement, to text: String) throws {
    var settable = DarwinBoolean(false)
    let readable = AXUIElementIsAttributeSettable(
        element, kAXValueAttribute as CFString, &settable)
    guard readable == .success, settable.boolValue else {
        throw DriverError.failure("native title TextField does not expose a writable AXValue")
    }
    let result = AXUIElementSetAttributeValue(
        element, kAXValueAttribute as CFString, text as CFString)
    guard result == .success else {
        throw DriverError.failure("AXValue set failed for title edit: \(result.rawValue)")
    }
}

func statusText(_ element: AXUIElement) -> String {
    let candidates = [
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
    ]
    return candidates.first { !$0.isEmpty } ?? ""
}

// Keyboard scenarios cannot be covered by AXPress alone: a text field needs
// real user-path key events after focus is asserted, which is how products
// exercise type/Return/Escape flows end to end.
func focus(_ element: AXUIElement, description: String) throws {
    let result = AXUIElementSetAttributeValue(
        element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard result == .success else {
        throw DriverError.failure("AX focus failed for \(description): \(result.rawValue)")
    }
    guard boolAttribute(element, kAXFocusedAttribute) else {
        throw DriverError.failure("\(description) did not take focus")
    }
}

func postKey(_ keyCode: CGKeyCode) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
        throw DriverError.failure("could not create key events for keycode \(keyCode)")
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// The packaged SwiftUI host receives genuine key-down/up events, not direct
// AXValue assignment. On macOS CI the old virtualKey=0 + injected Unicode
// string events were silently ignored by the focused TextField even though
// Cmd+A and foreground/focus checks succeeded. Use the verified US/ABC input
// layout and actual physical key codes for this deterministic ASCII fixture.
func typeText(_ text: String) throws {
    let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let sourceID = source.map(inputSourceID) ?? "<missing>"
    guard ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains(sourceID) else {
        throw DriverError.failure("test keyboard requires US/ABC layout, got \(sourceID)")
    }
    let codes: [String: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3,
        "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
        "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
        "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6, " ": 49,
    ]
    for character in text {
        let original = String(character)
        guard let keyCode = codes[original.lowercased()] else {
            throw DriverError.failure("test keyboard has no key code for \(String(reflecting: original))")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw DriverError.failure("could not create typing events")
        }
        let flags: CGEventFlags = original != original.lowercased() ? .maskShift : []
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Serialise HID events through the CI input queue; success is only
        // declared after the independent live AXValue and Racket RPC checks.
        Thread.sleep(forTimeInterval: 0.015)
    }
}

let kReturnKeyCode: CGKeyCode = 36
let kEscapeKeyCode: CGKeyCode = 53
let kQKeyCode: CGKeyCode = 12

// Posted CGEvents route to whatever application the session currently has
// focused, so every keyboard step needs proof that the app under test is
// frontmost — on a shared desktop a driver that skips this check can pour
// Cmd+A and Delete into a developer's editor (fail fast instead).
func keyboardGuard(_ application: AXUIElement, _ what: String) throws {
    if boolAttribute(application, kAXFrontmostAttribute) { return }
    _ = AXUIElementSetAttributeValue(
        application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if boolAttribute(application, kAXFrontmostAttribute) { return }
    _ = try waitFor("the application to take frontmost for \(what)") {
        boolAttribute(application, kAXFrontmostAttribute) ? true : nil
    }
}

// Third-party input methods intercept the text-input path: typed characters
// (and even Escape) never reach the app. Keyboard phases run under an
// ASCII-capable layout and restore the user's source afterwards.
var savedInputSource: TISInputSource?

func asciiCapable(_ source: TISInputSource) -> Bool {
    guard let property = TISGetInputSourceProperty(
        source, kTISPropertyInputSourceIsASCIICapable) else { return false }
    let value = Unmanaged<CFTypeRef>.fromOpaque(property).takeUnretainedValue()
    return (value as? Bool) == true
}

func inputSourceID(_ source: TISInputSource) -> String {
    guard let property = TISGetInputSourceProperty(
        source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
}

func selectASCIILayout() {
    savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
            as? [TISInputSource] else { return }
    var pick: TISInputSource?
    for source in sources where asciiCapable(source) {
        if inputSourceID(source) == "com.apple.keylayout.ABC" { pick = source; break }
        if pick == nil { pick = source }
    }
    if let pick { TISSelectInputSource(pick) }
}

func restoreInputSource() {
    if let savedInputSource { TISSelectInputSource(savedInputSource) }
}

// Orderly exit goes through the quit Apple Event (what Cmd+Q delivers): on
// current macOS, SIGTERM, programmatic termination, and the window close
// button can all be swallowed by a packaged app while the main thread idles,
// while the quit Apple Event reliably runs the shutdown. The frontmost guard
// keeps a sick instance from dropping Cmd+Q into the user's focused app; the
// suite's bounded kill reaps that case instead.
func quitOrderly(_ application: AXUIElement) {
    guard boolAttribute(application, kAXFrontmostAttribute) else { return }
    for keyDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: kQKeyCode, keyDown: keyDown) else {
            return
        }
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
}

do {
    let options = try parseOptions()
    try FileManager.default.createDirectory(
        at: options.output, withIntermediateDirectories: true)
    guard AXIsProcessTrusted() else {
        throw DriverError.failure(
            "the native AX driver is not trusted; the CI runner must grant accessibility to its test process")
    }

    let application = AXUIElementCreateApplication(options.pid)
    let window: AXUIElement
    do {
        window = try waitFor("the Taskboard window") {
            (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
        }
    } catch {
        captureStartupSpinEvidence(pid: options.pid, output: options.output)
        throw error
    }
    _ = AXUIElementSetAttributeValue(
        application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

    let expectedRoles = [
        "application-status": "AXStaticText",
        "task-list": "AXOutline",
        "new-task": "AXButton",
        "generate-demo": "AXButton",
    ]
    for (identifier, expectedRole) in expectedRoles {
        let element: AXUIElement = try waitFor("AXIdentifier \(identifier)") {
            find(window, identifier: identifier)
        }
        let actualRole = stringAttribute(element, kAXRoleAttribute)
        let acceptedListRole = identifier == "task-list" &&
            ["AXList", "AXTable"].contains(actualRole)
        guard actualRole == expectedRole || acceptedListRole else {
            throw DriverError.failure(
                "AXIdentifier \(identifier) exposed \(actualRole), expected \(expectedRole)")
        }
    }
    _ = try waitFor("the ready native controls") {
        guard let newTask = find(window, identifier: "new-task"),
              let generate = find(window, identifier: "generate-demo"),
              boolAttribute(newTask, kAXEnabledAttribute),
              boolAttribute(generate, kAXEnabledAttribute) else { return nil as Bool? }
        return true
    }

    try writeJSON(snapshot(application), to: options.output.appendingPathComponent("accessibility-before.json"))
    try press(try waitFor("new-task button") { find(window, identifier: "new-task") },
              description: "new-task")
    _ = try waitFor("the RPC-created task row") { find(window, identifier: "task-row-4") }

    // Native SwiftUI edit flow: typed draft is separate from the committed
    // task, explicit cancel restores the prior title, a rejected blank title
    // retains the field/error, and an accepted title reaches the real Racket
    // RPC before UI reports success. No simulated UI or mocked backend.
    func beginEdit() throws -> AXUIElement {
        try press(try waitFor("native Edit title button") {
            find(window, identifier: "edit-task")
        }, description: "edit-task")
        return try waitFor("native task title field") {
            find(window, identifier: "edit-task-title")
        }
    }
    let cancelEditor = try beginEdit()
    try setText(cancelEditor, to: "Discarded via macOS AX")
    try press(try waitFor("native Discard draft button") {
        find(window, identifier: "cancel-task-edit")
    }, description: "cancel-task-edit")
    _ = try waitFor("cancel restores original native title") {
        guard let label = find(window, identifier: "task-title"),
              statusText(label) == "New task" else { return nil as Bool? }
        return true
    }

    let rejectedEditor = try beginEdit()
    try setText(rejectedEditor, to: "   ")
    try press(try waitFor("native Apply title button") {
        find(window, identifier: "save-task")
    }, description: "save-task")
    _ = try waitFor("rejected save keeps the native draft editable") {
        guard let field = find(window, identifier: "edit-task-title"),
              let error = find(window, identifier: "task-edit-error"),
              stringAttribute(field, kAXValueAttribute) == "   ",
              statusText(error).contains("Update failed; draft retained") else {
            return nil as Bool?
        }
        return true
    }

    // The first write exercises AXValue accessibility. On retry, use the
    // actual keyboard input path: some SwiftUI TextField/AX implementations
    // expose an updated AXValue without propagating it to the SwiftUI binding.
    // A native user can recover by typing, so validate that route explicitly.
    let retryEditor = try waitFor("retained title TextField") {
        find(window, identifier: "edit-task-title")
    }
    try keyboardGuard(application, "retrying native title edit")
    selectASCIILayout()
    do {
        defer { restoreInputSource() }
        try focus(retryEditor, description: "retained native title field")
        func commandA() throws {
            for down in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: nil, virtualKey: 0, keyDown: down
                ) else {
                    throw DriverError.failure("could not create Command+A key event")
                }
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
        }
        // A posted Cmd+A key event is asynchronous. In CI the subsequent
        // Unicode keystrokes could arrive before the TextField had selected
        // the rejected draft. Wait for *observable* selection, not a sleep or
        // an AXValue assignment that might bypass the SwiftUI binding.
        try commandA()
        _ = try waitFor("Cmd+A selects the rejected title draft", timeout: 8) {
            guard let field = find(window, identifier: "edit-task-title"),
                  stringAttribute(field, kAXSelectedTextAttribute) == "   " else {
                return nil as Bool?
            }
            return true
        }
        try keyboardGuard(application, "typing the retry title after selection")
        try typeText("Edited via macOS AX")
        _ = try waitFor("retry title visible in native TextField") {
            guard let field = find(window, identifier: "edit-task-title"),
                  stringAttribute(field, kAXValueAttribute) == "Edited via macOS AX" else {
                return nil as Bool?
            }
            return true
        }
    } catch {
        // Preserve the *failure point* evidence as well as the existing
        // post-save error snapshot. Previously this exception escaped before
        // any retry-stage AX state was archived.
        let field = find(window, identifier: "edit-task-title")
        let draft = field.map { stringAttribute($0, kAXValueAttribute) } ?? "<missing>"
        let selected = field.map { stringAttribute($0, kAXSelectedTextAttribute) } ?? "<missing>"
        let focused = field.map { boolAttribute($0, kAXFocusedAttribute) } ?? false
        let frontmost = boolAttribute(application, kAXFrontmostAttribute)
        let keyboard = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let sourceID = keyboard.map(inputSourceID) ?? "<missing>"
        // A CFTypeRef conditional downcast to AXUIElement is rejected by
        // Swift on macOS. Check the actual AX type ID before the cast so
        // diagnostics remain safe when the system focus is absent or invalid.
        let rawSystemFocus = attribute(application, kAXFocusedUIElementAttribute)
        let systemFocus: String
        if let rawSystemFocus, CFGetTypeID(rawSystemFocus) == AXUIElementGetTypeID() {
            systemFocus = stringAttribute(rawSystemFocus as! AXUIElement, kAXIdentifierAttribute)
        } else {
            systemFocus = "<missing>"
        }
        // Preserve structured evidence even when the failure occurs before
        // Apply. String(reflecting:) makes whitespace-only drafts visible.
        try? writeJSON([
            "draft": draft,
            "selected": selected,
            "focused": focused,
            "frontmost": frontmost,
            "focusedIdentifier": systemFocus,
            "inputSourceID": sourceID,
            "underlying": String(describing: error),
        ], to: options.output.appendingPathComponent("retry-input-diagnostics.json"))
        try? writeJSON(snapshot(application),
                       to: options.output.appendingPathComponent("retry-input-failure-ax.json"))
        throw DriverError.failure(
            "native retry keyboard input failed: draft=\(String(reflecting: draft)) " +
            "selected=\(String(reflecting: selected)) focused=\(focused) " +
            "frontmost=\(frontmost) focusedIdentifier=\(systemFocus) " +
            "inputSource=\(sourceID); underlying=\(error)"
        )
    }
    try press(try waitFor("retry Apply title button") {
        find(window, identifier: "save-task")
    }, description: "save-task retry")
    do {
        _ = try waitFor("saved native detail title") {
            guard let label = find(window, identifier: "task-title"),
                  statusText(label) == "Edited via macOS AX" else { return nil as Bool? }
            return true
        }
    } catch {
        // Capture *actual* AX values on failure. A timeout without status/error
        // made the earlier failed run impossible to diagnose responsibly.
        let status = find(window, identifier: "application-status")
            .map(statusText) ?? "<missing>"
        let errorText = find(window, identifier: "task-edit-error")
            .map(statusText) ?? "<none>"
        let visibleTitle = find(window, identifier: "task-title")
            .map(statusText) ?? "<missing>"
        let draft = find(window, identifier: "edit-task-title")
            .map { stringAttribute($0, kAXValueAttribute) } ?? "<missing>"
        try? writeJSON(snapshot(application),
                       to: options.output.appendingPathComponent("edit-failure-accessibility.json"))
        throw DriverError.failure(
            "title retry failed: status=\(status) error=\(errorText) " +
            "visibleTitle=\(visibleTitle) draft=\(draft); underlying=\(error)"
        )
    }
    _ = try waitFor("explicit session-only save feedback") {
        guard let status = find(window, identifier: "application-status"),
              statusText(status).contains("resets on restart") else { return nil as Bool? }
        return true
    }

    // Keyboard path: Escape should not commit the draft. The existing
    // keyboardGuard prevents posting keystrokes into another foreground app.
    let escapeEditor = try beginEdit()
    try setText(escapeEditor, to: "Must not commit")
    try keyboardGuard(application, "title-edit Escape")
    try focus(escapeEditor, description: "native task title field")
    try postKey(kEscapeKeyCode)
    _ = try waitFor("keyboard Escape discards draft") {
        guard let label = find(window, identifier: "task-title"),
              statusText(label) == "Edited via macOS AX" else { return nil as Bool? }
        return true
    }

    try press(try waitFor("generate-demo button") { find(window, identifier: "generate-demo") },
              description: "generate-demo")
    var observed: [String] = []
    let eventDeadline = Date().addingTimeInterval(6)
    var sawEvent = false
    // The status element is re-found from the live tree on every probe: a
    // view that passes through an empty state can rebuild its controls and
    // turn captured AXUIElement references into zombies (issue #328).
    while Date() < eventDeadline {
        guard let status = find(window, identifier: "application-status") else {
            Thread.sleep(forTimeInterval: 0.01)
            continue
        }
        let value = statusText(status)
        if !value.isEmpty && observed.last != value { observed.append(value) }
        if value.hasPrefix("Preparing task ") { sawEvent = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard sawEvent else {
        throw DriverError.failure(
            "operation-progress Event never reached AX; observed=\(observed)")
    }
    _ = try waitFor("the RPC-driven 1,000-row state", timeout: 20) {
        guard let status = find(window, identifier: "application-status") else {
            return nil as Bool?
        }
        return statusText(status) == "Generated 1000 tasks" ? true : nil
    }

    try writeJSON(snapshot(application), to: options.output.appendingPathComponent("accessibility-after.json"))
    try writeJSON([
        "application": "Rivet Taskboard",
        "actions": ["press:new-task", "press:generate-demo"],
        "observedStatus": observed,
        "assertions": [
            "native SwiftUI window activated",
            "stable roles and AXIdentifiers exposed",
            "RPC-created task appeared",
            "operation-progress Event appeared",
            "1,000-row State reached the UI",
        ],
    ], to: options.output.appendingPathComponent("interaction-trace.json"))

    let screenshot = Process()
    screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    screenshot.arguments = ["-x", options.output.appendingPathComponent("screen.png").path]
    try screenshot.run()
    screenshot.waitUntilExit()
    guard screenshot.terminationStatus == 0 else {
        throw DriverError.failure("screencapture exited with status \(screenshot.terminationStatus)")
    }

    try keyboardGuard(application, "the orderly quit")
    quitOrderly(application)
} catch {
    FileHandle.standardError.write(Data("native macOS UI test failed: \(error)\n".utf8))
    exit(1)
}
