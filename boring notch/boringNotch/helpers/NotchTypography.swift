//
//  NotchTypography.swift
//  boringNotch — notch-only font selection + Orca-style usage refresh control
//
//  Font choice applies exclusively to the notch (ContentView tree).
//  Settings windows and keyboard-shortcut badges must not use these helpers.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Defaults

extension Defaults.Keys {
    /// Empty string = system SF font. Otherwise an installed font **family** name
    /// from `NSFontManager.availableFontFamilies` (e.g. `"04b03 Cyrillic"`).
    static let notchFontFamily = Key<String>("notchFontFamily", default: "")
}

// MARK: - System font catalog

enum NotchFontCatalog {
    /// Families pinned to the top of the picker when installed.
    static let pinnedFamilyNames: [String] = [
        "04b03 Cyrillic",
        "04b03",
    ]

    /// Sentinel for the system (SF) font in pickers / Defaults.
    static let systemFamilySentinel = ""

    /// All installed font family names, sorted; pinned families first.
    static var installedFamilies: [String] {
        let all = Set(NSFontManager.shared.availableFontFamilies)
        var ordered: [String] = []
        var seen = Set<String>()

        for pinned in pinnedFamilyNames where all.contains(pinned) {
            ordered.append(pinned)
            seen.insert(pinned)
        }

        for name in all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        where !seen.contains(name) {
            ordered.append(name)
        }
        return ordered
    }

    /// Filter by search query (empty → full list). Always includes `selected` if non-empty.
    static func choices(filter: String, selected: String) -> [String] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String]
        if q.isEmpty {
            base = installedFamilies
        } else {
            base = installedFamilies.filter { $0.localizedCaseInsensitiveContains(q) }
        }
        guard !selected.isEmpty, !base.contains(selected) else { return base }
        return [selected] + base
    }

    static func isInstalled(_ family: String) -> Bool {
        guard !family.isEmpty else { return true }
        return NSFontManager.shared.availableFontFamilies.contains(family)
    }

    static func displayName(for family: String) -> String {
        family.isEmpty ? L("System") : family
    }
}

// MARK: - Font helpers

enum NotchFont {
    /// Current family from Defaults ("" = system).
    static var family: String { Defaults[.notchFontFamily] }

    static var usesCustomFamily: Bool {
        let f = family
        return !f.isEmpty && NotchFontCatalog.isInstalled(f)
    }

    static func system(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        resolve(size: size, weight: weight)
    }

    static func system(_ textStyle: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let size = pointSize(for: textStyle)
        return resolve(size: size, weight: weight ?? .regular)
    }

    /// Fixed system font for keyboard-shortcut chrome (⌘N badges). Never follows notch font.
    static func shortcutBadge(size: CGFloat = 8, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Line height for marquee / layout measurement under the current notch font.
    static func lineHeight(for textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> CGFloat {
        let size = pointSize(for: textStyle)
        if let ns = resolvedNSFont(size: size, weight: weight) {
            return ceil(ns.ascender - ns.descender + ns.leading)
        }
        return size * 1.2
    }

    // MARK: resolve

    private static func resolve(size: CGFloat, weight: Font.Weight) -> Font {
        if let ns = resolvedNSFont(size: size, weight: weight) {
            return Font(ns)
        }
        return .system(size: size, weight: weight)
    }

    private static func resolvedNSFont(size: CGFloat, weight: Font.Weight) -> NSFont? {
        let family = Defaults[.notchFontFamily]
        guard !family.isEmpty else {
            return NSFont.systemFont(ofSize: size, weight: nsFontWeight(weight))
        }
        return nsFont(family: family, size: size, weight: weight)
            ?? NSFont(name: family, size: size)
    }

    private static func nsFont(family: String, size: CGFloat, weight: Font.Weight) -> NSFont? {
        let fm = NSFontManager.shared
        let w = nsWeightValue(weight)
        if let font = fm.font(withFamily: family, traits: [], weight: w, size: size) {
            return font
        }
        // Some pixel fonts only expose Regular — ignore weight request.
        if let font = fm.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        // Member PostScript name (e.g. "04b03-Cyrillic")
        if let members = fm.availableMembers(ofFontFamily: family),
           let first = members.first,
           let psName = first.first as? String,
           let font = NSFont(name: psName, size: size) {
            return font
        }
        return nil
    }

    private static func nsFontWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// NSFontManager weight scale ≈ 0…15 (5 = regular, 9 = bold).
    private static func nsWeightValue(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        case .black: return 11
        default: return 5
        }
    }

    private static func pointSize(for textStyle: Font.TextStyle) -> CGFloat {
        let nsStyle: NSFont.TextStyle
        switch textStyle {
        case .largeTitle: nsStyle = .largeTitle
        case .title: nsStyle = .title1
        case .title2: nsStyle = .title2
        case .title3: nsStyle = .title3
        case .headline: nsStyle = .headline
        case .subheadline: nsStyle = .subheadline
        case .body: nsStyle = .body
        case .callout: nsStyle = .callout
        case .footnote: nsStyle = .footnote
        case .caption: nsStyle = .caption1
        case .caption2: nsStyle = .caption2
        @unknown default: nsStyle = .body
        }
        return NSFont.preferredFont(forTextStyle: nsStyle).pointSize
    }
}

extension Font {
    /// Notch-scoped font. Prefer this over `.system` inside the notch tree.
    static func notch(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        NotchFont.system(size: size, weight: weight)
    }

    static func notch(_ textStyle: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        NotchFont.system(textStyle, weight: weight)
    }
}

// MARK: - Root modifier (ContentView)

/// Applies notch typography to the notch view tree without touching Settings.
struct NotchTypographyRoot: ViewModifier {
    @Default(.notchFontFamily) private var family

    func body(content: Content) -> some View {
        content
            .environment(\.notchFontFamily, family)
            // Force re-resolve of fonts that read Defaults when the family changes.
            .id("notch-font-\(family.isEmpty ? "system" : family)")
    }
}

private struct NotchFontFamilyKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var notchFontFamily: String {
        get { self[NotchFontFamilyKey.self] }
        set { self[NotchFontFamilyKey.self] = newValue }
    }
}

extension View {
    /// Call once at the root of the notch (not Settings).
    func notchTypography() -> some View {
        modifier(NotchTypographyRoot())
    }
}

// MARK: - Settings picker (system font database)

/// Font family picker for Appearance settings. System UI chrome only — no search/preview chrome.
struct NotchFontFamilyPicker: View {
    @Default(.notchFontFamily) private var family

    var body: some View {
        Picker(L("Notch font"), selection: $family) {
            Text(L("System"))
                .tag(NotchFontCatalog.systemFamilySentinel)

            ForEach(choices, id: \.self) { name in
                Text(name)
                    .font(previewFont(for: name))
                    .tag(name)
            }
        }
    }

    private var choices: [String] {
        NotchFontCatalog.choices(filter: "", selected: family)
    }

    private func previewFont(for name: String) -> Font {
        if let ns = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: 13) {
            return Font(ns)
        }
        return .custom(name, size: 13)
    }
}

// MARK: - Orca-style usage refresh button
//
// Matches Orca status-bar control (lucide RefreshCw size 11 + spin while fetching):
//   <button className="p-0.5 rounded ... disabled:opacity-40">
//     <RefreshCw size={11} className={isRefreshing ? 'animate-spin' : ''} />
//   </button>

struct UsageRefreshButton: View {
    var isRefreshing: Bool
    var action: () -> Void

    /// Continuous spin angle while fetching (Orca `animate-spin` on RefreshCw).
    @State private var spinAngle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                // Orca: RefreshCw size={11}; keep SF system so shortcut/settings fonts stay independent.
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .rotationEffect(.degrees(spinAngle))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .opacity(isRefreshing ? 0.4 : 1)
        .help(L("Refresh usage data"))
        .accessibilityLabel(L("Refresh rate limits"))
        .onChange(of: isRefreshing) { _, refreshing in
            if refreshing {
                spinAngle = 0
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    spinAngle = 0
                }
            }
        }
        .onAppear {
            if isRefreshing {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            }
        }
    }
}
