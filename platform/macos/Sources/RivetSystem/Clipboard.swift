import AppKit
import Foundation

/// Plain-text system clipboard access with a main-run-loop change observer.
///
/// AppKit does not publish pasteboard-change notifications. Rivet follows the
/// platform convention and polls `changeCount`; multiple mutations between
/// polls are intentionally coalesced into one callback carrying the newest
/// plain-text value (or `nil` for non-text contents).
@MainActor
public final class RivetClipboard {
    private let pasteboard: NSPasteboard
    private var changeTimer: Timer?
    private var observedChangeCount: Int
    private var changeHandler: ((String?) -> Void)?

    public convenience init() {
        self.init(pasteboard: .general)
    }

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        observedChangeCount = pasteboard.changeCount
    }

    isolated deinit {
        changeTimer?.invalidate()
    }

    public func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    /// Replaces every current representation with UTF-8/Unicode plain text.
    /// Returns `false` for an embedded NUL (not portable to Win32/GDK) or
    /// when AppKit refuses to declare the string value.
    @discardableResult
    public func writeText(_ text: String) -> Bool {
        guard !text.contains("\0") else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Starts or replaces clipboard observation. Pass `nil` to stop.
    /// Callbacks run on the main actor and do not fire for the initial value.
    public func setChangeHandler(
        pollInterval: TimeInterval = 0.25,
        _ handler: ((String?) -> Void)?
    ) {
        changeTimer?.invalidate()
        changeTimer = nil
        changeHandler = handler
        observedChangeCount = pasteboard.changeCount
        guard handler != nil else { return }

        let timer = Timer(timeInterval: max(0.05, pollInterval), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.pollForChanges() }
        }
        RunLoop.main.add(timer, forMode: .common)
        changeTimer = timer
    }

    func pollForTesting() {
        pollForChanges()
    }

    private func pollForChanges() {
        let current = pasteboard.changeCount
        guard current != observedChangeCount else { return }
        observedChangeCount = current
        changeHandler?(readText())
    }
}
