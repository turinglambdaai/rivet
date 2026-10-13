import Foundation

#if canImport(Carbon.HIToolbox)
import Carbon.HIToolbox

/// Global shortcuts on macOS through Carbon's `RegisterEventHotKey` — the
/// mechanism launcher-class applications use, and the macOS counterpart of
/// Rivet's Linux XDG-portal adapter and Windows `RegisterHotKey` adapter.
/// Linux binds shortcuts through a compositor prompt because Wayland has no
/// global grabs; macOS permits direct registration with an explicit trigger.
///
/// All methods and the activation callback run on the main thread, which
/// must run an event loop for activations to arrive.
public final class RivetGlobalShortcuts: @unchecked Sendable {
    public typealias ActivationHandler =
        @Sendable (_ shortcutID: String,
                   _ timestampMilliseconds: UInt64,
                   _ activationToken: String) -> Void

    /// Identifies a registered shortcut inside the Carbon event metadata.
    private static let hotKeySignature: OSType = 0x52565453  // 'RVTS'

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [UInt32: (ref: EventHotKeyRef?,
                                   id: String,
                                   modifiers: UInt32,
                                   keyCode: UInt32)] = [:]
    private var nextIndex: UInt32 = 1
    private var activationHandler: ActivationHandler?

    public init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Carbon does not retain user data; the owner's reference keeps
        // this object alive and deinit removes the handler before state
        // goes away.
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         hotKeyEventRouter,
                                         1, &spec,
                                         selfPointer,
                                         &eventHandler)
        if status != noErr {
            eventHandler = nil
        }
    }

    deinit {
        for entry in hotKeys.values {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
        }
        // Removing the handler guarantees no further callbacks reach the
        // object after deinit begins.
        if eventHandler != nil {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Carbon hot-key registration is available in every application
    /// context; the portal-less counterpart of the Linux support probe.
    public static func available() -> Bool { true }

    /// Registers `trigger` under `shortcutID`. The trigger grammar matches
    /// the Windows adapter: case-insensitive '+'-separated modifiers
    /// (ctrl|control, alt|option, shift, cmd|command|meta|super|win) and
    /// exactly one key (a–z, 0–9, f1–f20, space, tab, enter|return,
    /// escape|esc, backspace, delete|del, insert, home, end, pageup,
    /// pagedown, up, down, left, right, comma, period, slash, backslash,
    /// semicolon, quote, minus, equal, bracketleft, bracketright). `win`
    /// maps to Command. Returns false for an unparsable trigger or a
    /// duplicate id, exactly like the Windows `Register`.
    @discardableResult
    public func register(shortcutID: String, trigger: String) -> Bool {
        guard let parsed = Self.parse(trigger) else { return false }
        guard !hotKeys.values.contains(where: { $0.id == shortcutID }) else {
            return false
        }
        // RegisterHotKey refuses a duplicate live trigger on Windows;
        // Carbon does not, so this adapter enforces the same rule itself.
        guard !hotKeys.values.contains(where: {
            $0.modifiers == parsed.modifiers && $0.keyCode == parsed.keyCode
        }) else { return false }
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature,
                                     id: nextIndex)
        let status = RegisterEventHotKey(parsed.keyCode,
                                         parsed.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr else { return false }
        hotKeys[nextIndex] = (hotKeyRef, shortcutID,
                              parsed.modifiers, parsed.keyCode)
        nextIndex += 1
        return true
    }

    @discardableResult
    public func unregister(shortcutID: String) -> Bool {
        for (index, entry) in hotKeys where entry.id == shortcutID {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
            hotKeys.removeValue(forKey: index)
            return true
        }
        return false
    }

    public func setActivationHandler(_ handler: @escaping ActivationHandler) {
        activationHandler = handler
    }

    /// Parses a trigger into Carbon modifier flags and a virtual key code.
    /// Public for tests and for hosts that render trigger strings.
    public static func parse(_ trigger: String)
        -> (modifiers: UInt32, keyCode: UInt32)? {
        // omittingEmptySubsequences must stay false: "+a" and "a+" have an
        // empty token and must be rejected, not silently accepted.
        let tokens = trigger.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for token in tokens {
            switch token {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command", "meta", "super", "win":
                modifiers |= UInt32(cmdKey)
            default:
                guard keyCode == nil,
                      let code = Self.keyCode(for: token) else { return nil }
                keyCode = code
            }
        }
        guard let code = keyCode else { return nil }
        return (modifiers, code)
    }

    /// ANSI virtual-key codes follow the physical QWERTY layout, not the
    /// alphabet: kVK_ANSI_T is 0x11 while T is the 20th letter. Every key
    /// is therefore mapped through its Carbon constant.
    private static func keyCode(for token: String) -> UInt32? {
        let ansiKeys: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "s": UInt32(kVK_ANSI_S),
            "d": UInt32(kVK_ANSI_D), "f": UInt32(kVK_ANSI_F),
            "h": UInt32(kVK_ANSI_H), "g": UInt32(kVK_ANSI_G),
            "z": UInt32(kVK_ANSI_Z), "x": UInt32(kVK_ANSI_X),
            "c": UInt32(kVK_ANSI_C), "v": UInt32(kVK_ANSI_V),
            "b": UInt32(kVK_ANSI_B), "q": UInt32(kVK_ANSI_Q),
            "w": UInt32(kVK_ANSI_W), "e": UInt32(kVK_ANSI_E),
            "r": UInt32(kVK_ANSI_R), "y": UInt32(kVK_ANSI_Y),
            "t": UInt32(kVK_ANSI_T), "o": UInt32(kVK_ANSI_O),
            "u": UInt32(kVK_ANSI_U), "i": UInt32(kVK_ANSI_I),
            "p": UInt32(kVK_ANSI_P), "l": UInt32(kVK_ANSI_L),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K),
            "n": UInt32(kVK_ANSI_N), "m": UInt32(kVK_ANSI_M),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
            "space": UInt32(kVK_Space),
            "tab": UInt32(kVK_Tab),
            "enter": UInt32(kVK_Return),
            "return": UInt32(kVK_Return),
            "escape": UInt32(kVK_Escape),
            "esc": UInt32(kVK_Escape),
            // On Apple keyboards the PC Insert position is Help.
            "insert": UInt32(kVK_Help),
            "backspace": UInt32(kVK_Delete),
            "delete": UInt32(kVK_ForwardDelete),
            "del": UInt32(kVK_ForwardDelete),
            "home": UInt32(kVK_Home),
            "end": UInt32(kVK_End),
            "pageup": UInt32(kVK_PageUp),
            "pagedown": UInt32(kVK_PageDown),
            "up": UInt32(kVK_UpArrow),
            "down": UInt32(kVK_DownArrow),
            "left": UInt32(kVK_LeftArrow),
            "right": UInt32(kVK_RightArrow),
            "comma": UInt32(kVK_ANSI_Comma),
            "period": UInt32(kVK_ANSI_Period),
            "slash": UInt32(kVK_ANSI_Slash),
            "backslash": UInt32(kVK_ANSI_Backslash),
            "semicolon": UInt32(kVK_ANSI_Semicolon),
            "quote": UInt32(kVK_ANSI_Quote),
            "minus": UInt32(kVK_ANSI_Minus),
            "equal": UInt32(kVK_ANSI_Equal),
            "bracketleft": UInt32(kVK_ANSI_LeftBracket),
            "bracketright": UInt32(kVK_ANSI_RightBracket),
        ]
        if let code = ansiKeys[token] { return code }
        if token.first == "f", let number = Int(token.dropFirst()),
           (1...12).contains(number) {
            return UInt32(kVK_F1 + number - 1)
        }
        if token.first == "f", let number = Int(token.dropFirst()),
           (13...20).contains(number) {
            return UInt32(kVK_F13 + number - 13)
        }
        return nil
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        var actualSize = 0
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            &actualSize,
            &hotKeyID)
        guard status == noErr, hotKeyID.signature == Self.hotKeySignature,
              let entry = hotKeys[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        let milliseconds = UInt64(max(0, GetEventTime(event)) * 1000)
        if let handler = activationHandler {
            handler(entry.id, milliseconds, "")
        }
        return noErr
    }
}

/// The Carbon callback must be a C function pointer; route through the
/// installed user-data pointer back into the owning instance.
private func hotKeyEventRouter(_ nextHandler: EventHandlerCallRef?,
                               _ event: EventRef?,
                               _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let shortcuts = Unmanaged<RivetGlobalShortcuts>
        .fromOpaque(userData).takeUnretainedValue()
    return shortcuts.handleHotKeyEvent(event)
}

#endif  // canImport(Carbon.HIToolbox)
