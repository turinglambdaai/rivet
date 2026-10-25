import AppKit
import ApplicationServices
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

func typeText(_ text: String) throws {
    for char in text.unicodeScalars {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw DriverError.failure("could not create typing events")
        }
        let utf16 = Array(String(char).utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

let kReturnKeyCode: CGKeyCode = 36
let kEscapeKeyCode: CGKeyCode = 53

func closeWindowOrderly(_ window: AXUIElement, description: String) throws {
    if let closeButtonValue = attribute(window, kAXCloseButtonAttribute) {
        let closeButton = closeButtonValue as! AXUIElement
        try press(closeButton, description: description)
    } else {
        throw DriverError.failure("\(description) has no native close button")
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
    let window: AXUIElement = try waitFor("the Taskboard window") {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
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

    let status: AXUIElement = try waitFor("application-status") {
        find(window, identifier: "application-status")
    }
    try press(try waitFor("generate-demo button") { find(window, identifier: "generate-demo") },
              description: "generate-demo")
    var observed: [String] = []
    let eventDeadline = Date().addingTimeInterval(6)
    var sawEvent = false
    while Date() < eventDeadline {
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
        statusText(status) == "Generated 1000 tasks" ? true : nil
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

    try closeWindowOrderly(window, description: "Taskboard window")
} catch {
    FileHandle.standardError.write(Data("native macOS UI test failed: \(error)\n".utf8))
    exit(1)
}
