import AppKit
import Foundation
import UniformTypeIdentifiers

/// A user-facing file-kind label and its filename extensions. Extensions may
/// be supplied with or without a leading dot; invalid path or wildcard tokens
/// are discarded rather than reaching a platform dialog.
public struct RivetFileDialogFilter: Sendable, Equatable {
    public let label: String
    public let extensions: [String]

    public init(label: String, extensions: [String]) {
        self.label = label
        self.extensions = extensions.compactMap(Self.normalize)
    }

    private static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensionName = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        guard !extensionName.isEmpty,
              extensionName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\*?[]")) == nil
        else { return nil }
        return extensionName.lowercased()
    }
}

/// First-party AppKit open/save panels. Calls and completions stay on the main
/// actor; cancellation is the ordinary `nil` result, not an error.
@MainActor
public enum RivetFileDialogs {
    public static func openFiles(
        title: String? = nil,
        allowsMultipleSelection: Bool = false,
        chooseDirectories: Bool = false,
        filters: [RivetFileDialogFilter] = [],
        relativeTo window: NSWindow? = nil
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title ?? ""
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = chooseDirectories
        panel.canChooseFiles = !chooseDirectories
        if !chooseDirectories {
            panel.allowedContentTypes = contentTypes(for: filters)
        }

        let response = await present(panel, relativeTo: window)
        return response == .OK ? panel.urls : nil
    }

    public static func saveFile(
        title: String? = nil,
        suggestedName: String? = nil,
        filters: [RivetFileDialogFilter] = [],
        relativeTo window: NSWindow? = nil
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = title ?? ""
        panel.nameFieldStringValue = suggestedName ?? ""
        panel.allowedContentTypes = contentTypes(for: filters)

        let response = await present(panel, relativeTo: window)
        return response == .OK ? panel.url : nil
    }

    private static func contentTypes(for filters: [RivetFileDialogFilter]) -> [UTType] {
        filters.flatMap(\.extensions).compactMap { UTType(filenameExtension: $0) }
    }

    private static func present(
        _ panel: NSSavePanel,
        relativeTo window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
    }
}
