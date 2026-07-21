//
//  ClipboardHistoryManager.swift
//  boringNotch — headless manager adapted from Maccy History.swift
//

import AppKit
import Defaults
import Foundation
import SwiftData

@MainActor
final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()

    @Published private(set) var items: [HistoryItem] = []
    @Published var searchQuery: String = "" {
        didSet { applySearch() }
    }
    @Published private(set) var visibleItems: [HistoryItem] = []
    @Published var selectedIndex: Int = 0

    private let search = ClipboardSearch()
    private var allItems: [HistoryItem] = []
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // One-time: bring pre-cap Defaults (e.g. 200) down to 9
        Self.migrateHistorySizeCapIfNeeded()

        // Touch storage so container is ready
        _ = ClipboardStorage.shared.context

        ClipboardService.shared.onNewCopy { [weak self] item in
            Task { @MainActor in
                self?.add(item)
            }
        }
        ClipboardService.shared.start()

        Task { @MainActor in
            await load()
        }

        // React to enable toggle / interval changes
        Task {
            for await value in Defaults.updates(.clipboardEnabled) {
                if value {
                    ClipboardService.shared.start()
                } else {
                    ClipboardService.shared.stop()
                }
            }
        }
        Task {
            for await _ in Defaults.updates(.clipboardCheckInterval) {
                if Defaults[.clipboardEnabled] {
                    ClipboardService.shared.restart()
                }
            }
        }
        Task {
            for await _ in Defaults.updates(.clipboardHistorySize) {
                await MainActor.run {
                    self.limitHistorySize(to: Defaults[.clipboardHistorySize])
                    self.publish()
                }
            }
        }
    }

    func load() async {
        let descriptor = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        do {
            let results = try ClipboardStorage.shared.context.fetch(descriptor)
            // Repair media that only held fragile file URLs (pre-vault history).
            ClipboardMediaVault.migrateIfNeeded(results)
            allItems = sort(results)
            limitHistorySize(to: Defaults[.clipboardHistorySize])
            publish()
        } catch {
            print("Failed to load clipboard history: \(error)")
            allItems = []
            publish()
        }
    }

    @discardableResult
    func add(_ item: HistoryItem) -> HistoryItem {
        let context = ClipboardStorage.shared.context

        // Embed image bytes + vault-copy video/image files while sources are still readable.
        ClipboardMediaVault.materialize(item)

        context.insert(item)

        if let existing = findSimilarItem(item) {
            item.firstCopiedAt = existing.firstCopiedAt
            item.numberOfCopies += existing.numberOfCopies
            item.pin = existing.pin
            if item.title.isEmpty {
                item.title = existing.title
            }
            if !item.fromMaccy {
                item.application = existing.application
            }
            // Keep existing content if superseding empty-ish duplicate
            if item.contents.isEmpty {
                item.contents = existing.contents
            }
            ClipboardMediaVault.removeFiles(for: existing)
            context.delete(existing)
            allItems.removeAll { $0.persistentModelID == existing.persistentModelID }
        }

        limitHistorySize(to: Defaults[.clipboardHistorySize] - 1)

        allItems.insert(item, at: 0)
        allItems = sort(allItems)
        try? context.save()
        publish()
        return item
    }

    func delete(_ item: HistoryItem) {
        ClipboardMediaVault.removeFiles(for: item)
        ClipboardStorage.shared.context.delete(item)
        allItems.removeAll { $0.persistentModelID == item.persistentModelID }
        try? ClipboardStorage.shared.context.save()
        publish()
        clampSelection()
    }

    func deleteSelected() {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        delete(visibleItems[selectedIndex])
    }

    func clearUnpinned() {
        let unpinned = allItems.filter { !$0.isPinned }
        for item in unpinned {
            ClipboardMediaVault.removeFiles(for: item)
            ClipboardStorage.shared.context.delete(item)
        }
        allItems.removeAll { !$0.isPinned }
        try? ClipboardStorage.shared.context.save()
        publish()
        selectedIndex = 0
    }

    func togglePin(_ item: HistoryItem) {
        if item.pin == nil {
            item.pin = "•"
        } else {
            item.pin = nil
        }
        allItems = sort(allItems)
        try? ClipboardStorage.shared.context.save()
        publish()
    }

    func copySelected() {
        guard let item = selectedItem else { return }
        ClipboardService.shared.copy(item)
    }

    /// Bump item to front of unpinned (or pinned group) by refreshing lastCopiedAt, then re-sort.
    /// Own pasteboard writes are tagged `.fromMaccy` so the poller will not re-add a duplicate.
    func promoteCopied(_ item: HistoryItem) {
        item.lastCopiedAt = .now
        item.numberOfCopies += 1
        allItems = sort(allItems)
        try? ClipboardStorage.shared.context.save()
        publish()
        if let idx = visibleItems.firstIndex(where: { $0.persistentModelID == item.persistentModelID }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
    }

    func pasteSelected() {
        guard let item = selectedItem else { return }
        // Resign key so paste goes to previous app
        NSApp.windows.forEach { window in
            if window.isKeyWindow {
                window.resignKey()
            }
        }
        ClipboardService.shared.copy(item)
        // Small delay so focus returns to previous app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ClipboardService.shared.paste()
        }
    }

    func pasteItem(_ item: HistoryItem) {
        NSApp.windows.forEach { window in
            if window.isKeyWindow {
                window.resignKey()
            }
        }
        ClipboardService.shared.copy(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ClipboardService.shared.paste()
        }
    }

    var selectedItem: HistoryItem? {
        guard visibleItems.indices.contains(selectedIndex) else { return nil }
        return visibleItems[selectedIndex]
    }

    func moveSelection(dx: Int, dy: Int, columns: Int = 0) {
        guard !visibleItems.isEmpty else { return }
        if columns > 0 && dy != 0 {
            let next = selectedIndex + dy * columns
            if visibleItems.indices.contains(next) {
                selectedIndex = next
            }
        } else if dx != 0 {
            let next = selectedIndex + dx
            selectedIndex = max(0, min(visibleItems.count - 1, next))
        } else if dy != 0 {
            // Single-row fallback: up/down act as left/right
            let next = selectedIndex + dy
            selectedIndex = max(0, min(visibleItems.count - 1, next))
        }
    }

    func selectFirst() {
        selectedIndex = 0
    }

    // MARK: - Migration

    /// Force clipboardHistorySize ≤ 9 once (legacy default was 200).
    static func migrateHistorySizeCapIfNeeded() {
        guard !Defaults[.clipboardHistorySizeCappedTo9] else {
            // Still clamp if settings somehow exceed hard max
            if Defaults[.clipboardHistorySize] > 9 {
                Defaults[.clipboardHistorySize] = 9
            }
            return
        }
        if Defaults[.clipboardHistorySize] > 9 {
            Defaults[.clipboardHistorySize] = 9
        }
        Defaults[.clipboardHistorySizeCappedTo9] = true
    }

    // MARK: - Private

    private func publish() {
        items = allItems
        applySearch()
    }

    private func applySearch() {
        let searchable = allItems.map {
            ClipboardSearchable(id: $0.persistentModelID, title: $0.title.isEmpty ? $0.previewableText : $0.title, item: $0)
        }
        let results = search.search(string: searchQuery, within: searchable)
        visibleItems = results.map(\.object.item)
        clampSelection()
    }

    private func clampSelection() {
        if visibleItems.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, visibleItems.count - 1)
        }
    }

    private func sort(_ items: [HistoryItem]) -> [HistoryItem] {
        items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
    }

    private func limitHistorySize(to maxSize: Int) {
        let unpinned = allItems.filter { !$0.isPinned }
        guard unpinned.count > maxSize, maxSize >= 0 else { return }
        let excess = Array(unpinned.suffix(from: maxSize))
        for item in excess {
            ClipboardMediaVault.removeFiles(for: item)
            ClipboardStorage.shared.context.delete(item)
            allItems.removeAll { $0.persistentModelID == item.persistentModelID }
        }
        try? ClipboardStorage.shared.context.save()
    }

    private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
        allItems.first { existing in
            existing.persistentModelID != item.persistentModelID &&
            (existing.supersedes(item) || item.supersedes(existing))
        }
    }
}
