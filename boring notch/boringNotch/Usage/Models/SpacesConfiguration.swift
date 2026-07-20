//
//  SpacesConfiguration.swift
//  boringNotch — ordered notch “spaces” (tabs) with configurable icons.
//
//  ⌘N always maps to the N-th *visible* space in the current order
//  (not a fixed Home=1 / Shelf=2 mapping).
//

import Defaults
import Foundation
import SwiftUI

// MARK: - Icon catalog

/// Built-in icons a space can use (SF Symbol name or custom asset).
enum SpaceIconKind: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    // SF Symbols (default set)
    case house
    case tray
    case clipboard
    case chart
    case gauge
    case sparkles
    case star
    case bolt
    case heart
    case moon
    case sun
    case grid
    case terminal
    // Custom assets — Clawd mascot
    case mascotRed
    case mascotWhite

    var id: String { rawValue }

    var isCustomAsset: Bool {
        switch self {
        case .mascotRed, .mascotWhite: return true
        default: return false
        }
    }

    /// Clawd + speedometer render a bit larger than default SF Symbols in the tab bar.
    var prefersLargerTabSize: Bool {
        switch self {
        case .mascotRed, .mascotWhite, .gauge: return true
        default: return false
        }
    }

    /// White Clawd is a multicolor asset (white body + black eyes). Selection
    /// dims body via colorMultiply without washing out the eyes.
    var isWhiteClawd: Bool {
        self == .mascotWhite
    }

    /// SF Symbol name when not a custom asset.
    var systemName: String? {
        switch self {
        case .house: return "house.fill"
        case .tray: return "tray.fill"
        case .clipboard: return "doc.on.clipboard"
        case .chart: return "chart.bar.fill"
        case .gauge: return "gauge.with.dots.needle.67percent"
        case .sparkles: return "sparkles"
        case .star: return "star.fill"
        case .bolt: return "bolt.fill"
        case .heart: return "heart.fill"
        case .moon: return "moon.fill"
        case .sun: return "sun.max.fill"
        case .grid: return "square.grid.2x2.fill"
        case .terminal: return "terminal.fill"
        case .mascotRed, .mascotWhite: return nil
        }
    }

    /// Bundle / asset catalog names for custom icons.
    var assetNames: [String] {
        switch self {
        case .mascotRed: return ["usage_mascot", "UsageMascot"]
        case .mascotWhite: return ["usage_mascot_white", "UsageMascotWhite"]
        default: return []
        }
    }

    var displayNameKey: String {
        switch self {
        case .house: return "Home"
        case .tray: return "Shelf"
        case .clipboard: return "Clipboard"
        case .chart: return "Chart"
        case .gauge: return "Speedometer"
        case .sparkles: return "Sparkles"
        case .star: return "Star"
        case .bolt: return "Bolt"
        case .heart: return "Heart"
        case .moon: return "Moon"
        case .sun: return "Sun"
        case .grid: return "Grid"
        case .terminal: return "Terminal"
        case .mascotRed: return "Clawd (red)"
        case .mascotWhite: return "Clawd (white)"
        }
    }
}

// MARK: - Space identity

/// Stable space id — matches NotchViews cases used as tabs.
enum SpaceKind: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    case home
    case shelf
    case clipboard
    case usage

    var id: String { rawValue }

    var notchView: NotchViews {
        switch self {
        case .home: return .home
        case .shelf: return .shelf
        case .clipboard: return .clipboard
        case .usage: return .usage
        }
    }

    static func from(notchView: NotchViews) -> SpaceKind? {
        switch notchView {
        case .home: return .home
        case .shelf: return .shelf
        case .clipboard: return .clipboard
        case .usage: return .usage
        }
    }

    var defaultLabelKey: String {
        switch self {
        case .home: return "Home"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        case .usage: return "Usage"
        }
    }

    var defaultIcon: SpaceIconKind {
        switch self {
        case .home: return .house
        case .shelf: return .tray
        case .clipboard: return .clipboard
        case .usage: return .mascotWhite
        }
    }

    /// Feature flag gate (nil = always available).
    var isFeatureEnabled: Bool {
        switch self {
        case .home: return true
        case .shelf: return Defaults[.boringShelf]
        case .clipboard: return Defaults[.clipboardEnabled]
        case .usage: return Defaults[.usageTabEnabled]
        }
    }
}

// MARK: - Stored config entry

struct SpaceConfigEntry: Codable, Equatable, Identifiable, Defaults.Serializable {
    var kind: SpaceKind
    var icon: SpaceIconKind

    var id: String { kind.rawValue }

    static let defaults: [SpaceConfigEntry] = [
        .init(kind: .home, icon: .house),
        .init(kind: .shelf, icon: .tray),
        .init(kind: .clipboard, icon: .clipboard),
        .init(kind: .usage, icon: .mascotWhite)
    ]
}

extension Defaults.Keys {
    /// Ordered list of spaces (tabs). Missing kinds are appended with defaults.
    static let spacesOrder = Key<[SpaceConfigEntry]>("spacesOrder", default: SpaceConfigEntry.defaults)
}

// MARK: - Store

@MainActor
final class SpacesStore: ObservableObject {
    static let shared = SpacesStore()

    @Published private(set) var entries: [SpaceConfigEntry]

    private init() {
        entries = Self.normalized(Defaults[.spacesOrder])
        // One-shot: default Usage icon is white Clawd (replaces older chart default).
        migrateUsageDefaultIconIfNeeded()
        // Keep Defaults in sync if we had to repair missing kinds / migrate.
        if entries != Defaults[.spacesOrder] {
            Defaults[.spacesOrder] = entries
        }
    }

    /// Users who still have the old default chart icon on Usage get white Clawd.
    private func migrateUsageDefaultIconIfNeeded() {
        guard let idx = entries.firstIndex(where: { $0.kind == .usage }) else { return }
        // Only migrate the legacy default (chart), never override a deliberate choice.
        if entries[idx].icon == .chart {
            entries[idx].icon = .mascotWhite
        }
    }

    /// All spaces in user order (including disabled-by-feature).
    var orderedEntries: [SpaceConfigEntry] { entries }

    /// Visible spaces only (feature flags), preserving order. ⌘N uses this list.
    var visibleEntries: [SpaceConfigEntry] {
        entries.filter { $0.kind.isFeatureEnabled }
    }

    /// First visible space — used when the notch opens (unless “open last tab”).
    var firstVisibleNotchView: NotchViews {
        visibleEntries.first?.kind.notchView ?? .home
    }

    func icon(for kind: SpaceKind) -> SpaceIconKind {
        entries.first(where: { $0.kind == kind })?.icon ?? kind.defaultIcon
    }

    func setIcon(_ icon: SpaceIconKind, for kind: SpaceKind) {
        guard let idx = entries.firstIndex(where: { $0.kind == kind }) else { return }
        entries[idx].icon = icon
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    /// Reorder by dragging space `kind` to the position of `target` (before target).
    func move(kind: SpaceKind, before target: SpaceKind?) {
        guard let from = entries.firstIndex(where: { $0.kind == kind }) else { return }
        var list = entries
        let item = list.remove(at: from)
        if let target, let to = list.firstIndex(where: { $0.kind == target }) {
            list.insert(item, at: to)
        } else {
            list.append(item)
        }
        entries = list
        persist()
    }

    /// Drag among *visible* spaces only — maps back into full order.
    func moveVisible(fromOffsets: IndexSet, toOffset: Int) {
        var visible = visibleEntries
        guard !fromOffsets.isEmpty else { return }
        visible.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // Rebuild full list: new visible order, keep disabled in relative positions after their neighbors.
        let disabled = entries.filter { !$0.kind.isFeatureEnabled }
        var rebuilt = visible
        // Append any disabled at end of their original relative order
        for d in disabled {
            rebuilt.append(d)
        }
        // Ensure all kinds present
        entries = Self.normalized(rebuilt)
        persist()
    }

    func resetToDefaults() {
        entries = SpaceConfigEntry.defaults
        persist()
    }

    private func persist() {
        Defaults[.spacesOrder] = entries
        objectWillChange.send()
    }

    /// Ensure every SpaceKind appears exactly once.
    private static func normalized(_ raw: [SpaceConfigEntry]) -> [SpaceConfigEntry] {
        var seen = Set<SpaceKind>()
        var result: [SpaceConfigEntry] = []
        for e in raw {
            if seen.insert(e.kind).inserted {
                result.append(e)
            }
        }
        for kind in SpaceKind.allCases where !seen.contains(kind) {
            result.append(.init(kind: kind, icon: kind.defaultIcon))
        }
        return result
    }
}

// MARK: - Icon view

struct SpaceIconView: View {
    let icon: SpaceIconKind
    var size: CGFloat = 14
    /// Active tab (selected space) vs inactive — drives white Clawd tint.
    var selected: Bool = true

    var body: some View {
        Group {
            if icon.isCustomAsset {
                customAsset
            } else if let name = icon.systemName {
                Image(systemName: name)
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "questionmark")
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        // Same inactive treatment as SF Symbol tabs (parent .gray + slight fade).
        .opacity(selected ? 1 : 0.55)
    }

    @ViewBuilder
    private var customAsset: some View {
        if let nsImage = OrcaIconLoader.image(names: icon.assetNames) {
            // White Clawd: white body + black eyes. Multiply by the same gray used
            // for unselected SF Symbol spaces so body matches other tabs.
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .colorMultiply(icon.isWhiteClawd
                               ? (selected ? Color.white : Color.gray)
                               : Color.white)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.22), style: .continuous))
        } else {
            Image(systemName: "face.smiling")
                .font(.system(size: size * 0.85))
                .foregroundStyle(icon == .mascotRed
                                 ? Color(red: 1, green: 0.35, blue: 0.3)
                                 : (selected ? Color.white : Color.gray))
                .frame(width: size, height: size)
        }
    }
}
