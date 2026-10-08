import AppKit
import Darwin
import Foundation
import Security
import ServiceManagement
import UserNotifications

public enum RivetSystemError: Error, CustomStringConvertible {
    case posix(String, Int32)
    case keychain(OSStatus)
    case invalidUTF8
    case notificationsUnavailable

    public var description: String {
        switch self {
        case .posix(let operation, let code): return "\(operation) failed (errno \(code))"
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidUTF8: return "stored secret is not valid UTF-8"
        case .notificationsUnavailable:
            return "macOS notifications require a packaged .app bundle with an application identifier"
        }
    }
}

/// A process-wide lock backed by flock(2). The lock descriptor remains open
/// for the lifetime of the object, and is released automatically on crash.
public final class RivetSingleInstance: @unchecked Sendable {
    private let descriptor: Int32
    public let isPrimary: Bool

    public init(applicationID: String) throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rivet/InstanceLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safeID = applicationID.replacingOccurrences(of: "/", with: "_")
        let path = root.appendingPathComponent(safeID + ".lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RivetSystemError.posix("open", errno) }
        isPrimary = flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if descriptor >= 0 {
            if isPrimary { _ = flock(descriptor, LOCK_UN) }
            _ = Darwin.close(descriptor)
        }
    }
}

public enum RivetSecureStorage {
    public static func set(service: String, account: String, secret: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: secret]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var inserted = query
            inserted[kSecValueData as String] = secret
            let status = SecItemAdd(inserted as CFDictionary, nil)
            guard status == errSecSuccess else { throw RivetSystemError.keychain(status) }
        } else if updated != errSecSuccess {
            throw RivetSystemError.keychain(updated)
        }
    }

    public static func get(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RivetSystemError.keychain(status) }
        return result as? Data
    }

    public static func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RivetSystemError.keychain(status)
        }
    }
}

public enum RivetNotifications {
    /// UserNotifications raises an Objective-C exception, rather than a Swift
    /// error, when invoked by a command-line executable outside an app bundle.
    /// Check the process identity before crossing that framework boundary.
    public static var isAvailable: Bool {
        isAvailable(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func isAvailable(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && !(bundleIdentifier?.isEmpty ?? true)
    }

    public static func requestAuthorization() async throws -> Bool {
        guard isAvailable else { return false }
        return try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
    }

    public static func show(title: String, body: String, identifier: String = UUID().uuidString) async throws {
        guard isAvailable else { throw RivetSystemError.notificationsUnavailable }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

@available(macOS 13.0, *)
public enum RivetLoginItem {
    public static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// One entry of a status-bar menu. `.separator` renders an `NSMenuItem.separator()`
/// and never carries an action; `.action` entries dispatch by `identifier`.
public enum RivetMenuItem {
    case action(label: String, identifier: String, handler: () -> Void)
    case separator
}

@MainActor
public final class RivetMenuBarController: NSObject {
    private var item: NSStatusItem?
    private var menu: NSMenu?
    private var actions: [String: () -> Void] = [:]
    private var currentItems: [RivetMenuItem] = []
    private var currentToolTip: String?
    // AppKit does not send the button action while NSStatusItem.menu is set.
    // Click-action mode therefore detaches (but retains) the menu.
    private var clickHandler: (() -> Void)?

    public func install(title: String, menuItems: [(String, String, () -> Void)]) {
        install(
            title: title,
            items: menuItems.map {
                .action(label: $0.0, identifier: $0.1, handler: $0.2)
            })
    }

    public func install(title: String, items: [RivetMenuItem]) {
        installStatusItem { button in
            button.title = title
        }
        rebuild(items: items)
    }

    /// Template image in place of a text title; rendered as a template so it
    /// follows the menu bar's light/dark appearance.
    public func install(icon: NSImage, items: [RivetMenuItem]) {
        icon.isTemplate = true
        installStatusItem { button in
            button.image = icon
        }
        rebuild(items: items)
    }

    /// Replace every menu entry in place (labels, handlers, separators),
    /// keeping the status item, title/icon, and tooltip.
    public func update(items: [RivetMenuItem]) {
        rebuild(items: items)
    }

    /// Swap one entry's label without rebuilding the whole menu.
    public func setItem(_ identifier: String, label: String) {
        guard let menu else { return }
        for entry in menu.items
        where entry.representedObject as? String == identifier {
            entry.title = label
        }
        currentItems = currentItems.map { current in
            guard case let .action(_, currentIdentifier, handler) = current,
                  currentIdentifier == identifier
            else { return current }
            return .action(label: label, identifier: currentIdentifier, handler: handler)
        }
    }

    public func setToolTip(_ text: String?) {
        currentToolTip = text
        item?.button?.toolTip = text
    }

    /// Switch between click-action and menu modes. AppKit does not dispatch a
    /// status-button action while a menu is attached, so a non-nil handler
    /// temporarily hides the menu. Pass nil to restore menu-at-click.
    public func setClickAction(_ handler: (() -> Void)?) {
        clickHandler = handler
        guard let item, let button = item.button else { return }
        if handler != nil {
            item.menu = nil
            button.target = self
            button.action = #selector(handleClick(_:))
        } else {
            button.target = nil
            button.action = nil
            item.menu = menu
        }
    }

    public func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        menu = nil
        actions.removeAll()
        currentItems = []
        currentToolTip = nil
        clickHandler = nil
    }

    /// Test hook: the live NSMenu backing the status item.
    var menuForTesting: NSMenu? { item?.menu }
    var retainedMenuForTesting: NSMenu? { menu }
    var buttonForTesting: NSStatusBarButton? { item?.button }

    // MARK: internals

    private func installStatusItem(_ configure: (NSStatusBarButton) -> Void) {
        if let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            configure(button)
            button.toolTip = currentToolTip
            if clickHandler != nil {
                button.action = #selector(handleClick(_:))
                button.target = self
            }
        }
        item = statusItem
    }

    private func rebuild(items: [RivetMenuItem]) {
        let menu = NSMenu()
        actions.removeAll()
        for entry in items {
            switch entry {
            case let .action(label, identifier, action):
                actions[identifier] = action
                let item = NSMenuItem(
                    title: label, action: #selector(invoke(_:)), keyEquivalent: "")
                item.representedObject = identifier
                item.target = self
                menu.addItem(item)
            case .separator:
                menu.addItem(NSMenuItem.separator())
            }
        }
        self.menu = menu
        item?.menu = clickHandler == nil ? menu : nil
        currentItems = items
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        actions[identifier]?()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        clickHandler?()
    }
}

public final class RivetActivationRouter {
    public var onURLs: (([URL]) -> Void)?
    public init() {}
    public func handle(_ urls: [URL]) { onURLs?(urls) }
}
