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

    public var description: String {
        switch self {
        case .posix(let operation, let code): return "\(operation) failed (errno \(code))"
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidUTF8: return "stored secret is not valid UTF-8"
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
    public static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
    }

    public static func show(title: String, body: String, identifier: String = UUID().uuidString) async throws {
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

@MainActor
public final class RivetMenuBarController: NSObject {
    private var item: NSStatusItem?
    private var actions: [String: () -> Void] = [:]

    public func install(title: String, menuItems: [(String, String, () -> Void)]) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = title
        let menu = NSMenu()
        for (label, identifier, action) in menuItems {
            actions[identifier] = action
            let entry = NSMenuItem(title: label, action: #selector(invoke(_:)), keyEquivalent: "")
            entry.representedObject = identifier
            entry.target = self
            menu.addItem(entry)
        }
        statusItem.menu = menu
        item = statusItem
    }

    public func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        actions.removeAll()
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        actions[identifier]?()
    }
}

public final class RivetActivationRouter {
    public var onURLs: (([URL]) -> Void)?
    public init() {}
    public func handle(_ urls: [URL]) { onURLs?(urls) }
}
