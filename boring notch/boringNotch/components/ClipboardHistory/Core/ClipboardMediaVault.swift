//
//  ClipboardMediaVault.swift
//  boringNotch — durable media storage for clipboard history
//
//  Problem: Finder / many apps put images & videos on the pasteboard as *file URLs*
//  only. After the app restarts, sandbox + deleted temp files mean those URLs no
//  longer load → cards go blank.
//
//  Fix on capture (and migrate on load):
//    • Images  → embed bitmap Data into HistoryItemContent (survives restart)
//    • Videos  → copy the file into Application Support/ClipboardMedia and
//                rewrite the fileURL content to the durable path
//    • Image files also get a vault copy when useful for Quick Look
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ClipboardMediaVault {
    private static let folderName = "ClipboardMedia"
    private static let markerType = "org.boringnotch.clipboard.media-vault"

    static var rootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Call right after creating a HistoryItem from the pasteboard, before save.
    static func materialize(_ item: HistoryItem) {
        ensureRoot()
        embedImageDataIfNeeded(item)
        relocateMediaFileURLs(item)
        markMaterialized(item)
    }

    /// Repair older history rows that only hold fragile file URLs.
    static func migrateIfNeeded(_ items: [HistoryItem]) {
        ensureRoot()
        var changed = false
        for item in items {
            if isMaterialized(item) {
                // Still rewrite missing image data when vault/file is reachable.
                let before = item.contents.count
                embedImageDataIfNeeded(item)
                if item.contents.count != before { changed = true }
                continue
            }
            embedImageDataIfNeeded(item)
            relocateMediaFileURLs(item)
            markMaterialized(item)
            changed = true
        }
        if changed {
            try? ClipboardStorage.shared.context.save()
        }
    }

    /// Remove vault files owned by a history item (on delete / eviction).
    static func removeFiles(for item: HistoryItem) {
        let root = rootURL.path
        for url in item.fileURLs {
            guard url.isFileURL, url.path.hasPrefix(root) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Image embedding

    /// Prefer pasteboard bitmap. If missing, read image file URL while still accessible.
    private static func embedImageDataIfNeeded(_ item: HistoryItem) {
        if item.imageData != nil { return }

        for url in item.fileURLs {
            guard url.isFileURL, isImageFile(url) else { continue }
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }

            let type = pasteboardType(forImageAt: url, data: data)
            // Avoid duplicate type rows.
            if item.contents.contains(where: { $0.type == type.rawValue && $0.value != nil }) {
                return
            }
            item.contents.append(HistoryItemContent(type: type.rawValue, value: data))
            return
        }
    }

    // MARK: - File relocation

    private static func relocateMediaFileURLs(_ item: HistoryItem) {
        let root = rootURL
        for content in item.contents {
            guard content.type == NSPasteboard.PasteboardType.fileURL.rawValue,
                  let value = content.value,
                  let source = URL(dataRepresentation: value, relativeTo: nil, isAbsolute: true),
                  source.isFileURL else { continue }

            // Already durable?
            if source.path.hasPrefix(root.path) { continue }

            let isImage = isImageFile(source)
            let isVideo = isVideoFile(source)
            guard isImage || isVideo else { continue }

            // Prefer embedding images (above). Still vault-copy so Quick Look / paste
            // keep a stable file URL after the original is gone.
            guard let durable = copyIntoVault(from: source) else { continue }
            content.value = durable.dataRepresentation
        }
    }

    private static func copyIntoVault(from source: URL) -> URL? {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: source.path) else { return nil }

        let ext = source.pathExtension.isEmpty ? defaultExtension(for: source) : source.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = rootURL.appendingPathComponent(name)

        do {
            // copyItem preserves original; for security-scoped sources we already
            // could read the path at capture time.
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            return dest
        } catch {
            // Fallback: stream bytes (works when copyItem fails on some volumes).
            do {
                let data = try Data(contentsOf: source)
                try data.write(to: dest, options: [.atomic])
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                return dest
            } catch {
                return nil
            }
        }
    }

    // MARK: - Markers / helpers

    private static func markMaterialized(_ item: HistoryItem) {
        guard !isMaterialized(item) else { return }
        item.contents.append(
            HistoryItemContent(type: markerType, value: Data("1".utf8))
        )
    }

    private static func isMaterialized(_ item: HistoryItem) -> Bool {
        item.contents.contains { $0.type == markerType }
    }

    private static func ensureRoot() {
        _ = rootURL
    }

    private static func isImageFile(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent)
        }
        return false
    }

    private static func pasteboardType(forImageAt url: URL, data: Data) -> NSPasteboard.PasteboardType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default:
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
            return .tiff
        }
    }

    private static func defaultExtension(for url: URL) -> String {
        if isVideoFile(url) { return "mp4" }
        if isImageFile(url) { return "png" }
        return "bin"
    }
}
