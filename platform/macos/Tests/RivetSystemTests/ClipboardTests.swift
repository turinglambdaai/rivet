import AppKit
import Testing
@testable import RivetSystem

@MainActor
@Test func clipboardReadsWritesAndObservesPlainText() {
    let pasteboard = NSPasteboard(name: .init("dev.rivet.tests.\(UUID().uuidString)"))
    pasteboard.clearContents()
    defer { pasteboard.releaseGlobally() }

    let clipboard = RivetClipboard(pasteboard: pasteboard)
    #expect(clipboard.readText() == nil)
    #expect(clipboard.writeText("Rivet clipboard ✓"))
    #expect(clipboard.readText() == "Rivet clipboard ✓")
    #expect(!clipboard.writeText("before\0after"))
    #expect(clipboard.readText() == "Rivet clipboard ✓")

    var observed: [String?] = []
    clipboard.setChangeHandler { observed.append($0) }
    #expect(clipboard.writeText("second"))
    clipboard.pollForTesting()
    #expect(observed == ["second"])

    // An unchanged changeCount must not produce duplicate callbacks.
    clipboard.pollForTesting()
    #expect(observed == ["second"])

    // Non-text ownership changes are reported as nil.
    pasteboard.clearContents()
    pasteboard.setData(Data([0, 1, 2]), forType: .init("dev.rivet.binary"))
    clipboard.pollForTesting()
    #expect(observed.count == 2)
    #expect(observed[1] == nil)

    clipboard.setChangeHandler(nil)
}
