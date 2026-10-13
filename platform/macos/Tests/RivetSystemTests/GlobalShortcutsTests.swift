import Carbon.HIToolbox
import Foundation
import Testing
@testable import RivetSystem

@Suite(.serialized)  // shares the Carbon application event target
@MainActor
struct RivetGlobalShortcutsTests {
    @Test func parseAcceptsModifiersAndKeys() {
        let cmdShiftSpace = RivetGlobalShortcuts.parse("Cmd+Shift+Space")
        #expect(cmdShiftSpace?.modifiers == UInt32(cmdKey | shiftKey))
        #expect(cmdShiftSpace?.keyCode == UInt32(kVK_Space))

        let ctrlAltT = RivetGlobalShortcuts.parse("CTRL+alt+t")
        #expect(ctrlAltT?.modifiers == UInt32(controlKey | optionKey))
        #expect(ctrlAltT?.keyCode == UInt32(kVK_ANSI_T))

        #expect(RivetGlobalShortcuts.parse("cmd+1")?.keyCode == UInt32(kVK_ANSI_1))
        #expect(RivetGlobalShortcuts.parse("super+f13")?.keyCode == UInt32(kVK_F13))
        #expect(RivetGlobalShortcuts.parse("option+delete")?
            .keyCode == UInt32(kVK_ForwardDelete))
        #expect(RivetGlobalShortcuts.parse("shift+backspace")?
            .keyCode == UInt32(kVK_Delete))
        #expect(RivetGlobalShortcuts.parse("win+left")?.modifiers == UInt32(cmdKey))

        let bare = RivetGlobalShortcuts.parse("a")
        #expect(bare?.modifiers == 0)
        #expect(bare?.keyCode == UInt32(kVK_ANSI_A))
    }

    @Test func parseRejectsMalformedTriggers() {
        #expect(RivetGlobalShortcuts.parse("") == nil)
        #expect(RivetGlobalShortcuts.parse("cmd+") == nil)
        #expect(RivetGlobalShortcuts.parse("cmd") == nil)
        #expect(RivetGlobalShortcuts.parse("foo+a") == nil)
        #expect(RivetGlobalShortcuts.parse("a+b") == nil)
        #expect(RivetGlobalShortcuts.parse("+a") == nil)
        #expect(RivetGlobalShortcuts.parse("cmd+shift+ctrl+alt+meta+hyper+a") == nil)
        #expect(RivetGlobalShortcuts.parse("f25") == nil)
        #expect(RivetGlobalShortcuts.parse("f0") == nil)
        #expect(RivetGlobalShortcuts.parse("cmd+home+l") == nil)
    }

    @Test func registrationLifecycleRoundTrips() {
        // Beyond every shipped Apple keyboard; registering it cannot shadow
        // a real user shortcut during the test.
        let shortcuts = RivetGlobalShortcuts()
        #expect(RivetGlobalShortcuts.available())
        #expect(shortcuts.register(shortcutID: "obscure", trigger: "Ctrl+Alt+Shift+F20"))
        // Duplicate ids and duplicate live triggers are refused.
        #expect(!shortcuts.register(shortcutID: "obscure", trigger: "Ctrl+Alt+Shift+F19"))
        #expect(!shortcuts.register(shortcutID: "other", trigger: "ctrl+alt+shift+f20"))
        #expect(shortcuts.unregister(shortcutID: "obscure"))
        #expect(!shortcuts.unregister(shortcutID: "obscure"))
        // The freed trigger is registerable again under another id.
        #expect(shortcuts.register(shortcutID: "other", trigger: "ctrl+alt+shift+f20"))
        #expect(shortcuts.unregister(shortcutID: "other"))
    }
}
