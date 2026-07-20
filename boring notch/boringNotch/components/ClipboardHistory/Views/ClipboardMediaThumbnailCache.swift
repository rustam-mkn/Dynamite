//
//  ClipboardMediaThumbnailCache.swift
//  boringNotch — resized image + video frame thumbnails for clipboard cards
//

import AppKit
import Foundation
import SwiftData

/// Shared cache of card-sized media previews so horizontal scroll stays cheap.
@MainActor
enum ClipboardMediaThumbnailCache {
    private static var images: [String: NSImage] = [:]
    private static var inflight: [String: Task<NSImage?, Never>] = [:]
    private static let lock = NSLock()

    /// Point size of the card; retinas scale inside generators.
    static func thumbnail(for item: HistoryItem, size: CGSize) async -> NSImage? {
        let key = cacheKey(for: item, size: size)

        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            return cached
        }
        if let existing = inflight[key] {
            lock.unlock()
            return await existing.value
        }
        lock.unlock()

        let task = Task<NSImage?, Never> {
            let image = await generate(for: item, size: size)
            lock.lock()
            if let image {
                images[key] = image
            }
            inflight[key] = nil
            lock.unlock()
            return image
        }

        lock.lock()
        inflight[key] = task
        lock.unlock()

        return await task.value
    }

    /// Synchronous hit only — used to avoid a flash when the view reappears.
    static func cached(for item: HistoryItem, size: CGSize) -> NSImage? {
        let key = cacheKey(for: item, size: size)
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    static func clear() {
        lock.lock()
        images.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private static func cacheKey(for item: HistoryItem, size: CGSize) -> String {
        // persistentModelID is stable after insert; include lastCopiedAt so re-copies refresh.
        "\(item.persistentModelID)_\(item.lastCopiedAt.timeIntervalSince1970)_\(Int(size.width))x\(Int(size.height))"
    }

    private static func generate(for item: HistoryItem, size: CGSize) async -> NSImage? {
        // Prefer bitmap pasteboard data / image file → NSImage, resized for the card.
        if let raw = item.image {
            return await resizeOnBackground(raw, to: size)
        }

        // Video (or image file that failed NSImage): Quick Look content preview (not type icon).
        if let url = item.mediaPreviewURL ?? item.videoFileURL {
            let pointSize = CGSize(
                width: max(size.width, 1),
                height: max(size.height, 1)
            )
            if let ql = await ThumbnailService.shared.thumbnail(
                for: url,
                size: pointSize,
                iconMode: false
            ) {
                return ql
            }
            // Fallback: workspace file icon (better than empty)
            return ClipboardIconCache.fileIcon(path: url.path)
        }

        return nil
    }

    private static func resizeOnBackground(_ image: NSImage, to size: CGSize) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            Self.resizedFitting(image, in: size)
        }.value
    }

    /// Scale so the image covers `size` (fill), then crop to center — matches card `.fill` look.
    nonisolated private static func resizedFitting(_ image: NSImage, in target: CGSize) -> NSImage {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0,
              target.width > 0, target.height > 0 else {
            return image
        }

        let scale = max(target.width / srcSize.width, target.height / srcSize.height)
        // Don't enlarge tiny images past ~2× source — keep crisp icons sharp.
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)

        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let origin = NSPoint(
            x: (target.width - drawSize.width) / 2,
            y: (target.height - drawSize.height) / 2
        )
        image.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        out.unlockFocus()
        return out
    }
}
