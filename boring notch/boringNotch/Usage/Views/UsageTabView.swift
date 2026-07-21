//
//  UsageTabView.swift
//  boringNotch — Orca-style usage:
//    default: providers in a single horizontal strip (status-bar chips)
//    click:   detail panel for that provider (popover layout)
//

import SwiftUI

struct UsageTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var rateLimits = RateLimitService.shared
    @ObservedObject private var language = LanguageManager.shared

    @State private var now = Date()
    /// Selected provider for expanded detail; nil = compact strip.
    @State private var expandedProvider: UsageProviderID?

    var body: some View {
        GeometryReader { geo in
            let providers = displayProviders
            ZStack {
                if providers.allSatisfy({ $0.status == .unavailable || $0.status == .idle })
                    && !rateLimits.isFetching
                    && providers.allSatisfy({ $0.session == nil && $0.weekly == nil && $0.monthly == nil && $0.fableWeekly == nil }) {
                    emptyState
                } else if let expanded = expandedProvider,
                          let limits = providers.first(where: { $0.provider == expanded }) {
                    ProviderDetailPanel(
                        limits: limits,
                        now: now,
                        isFetching: rateLimits.isFetching,
                        onBack: {
                            withAnimation(.smooth(duration: 0.22)) {
                                expandedProvider = nil
                            }
                        },
                        onSignIn: {
                            ProviderAuthService.beginSignIn(for: limits.provider)
                        },
                        onRefresh: {
                            Task { await rateLimits.refresh(force: true) }
                        }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                } else {
                    compactListWithMascot(providers: providers, size: geo.size)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.22), value: expandedProvider)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(language.revision)
        .onAppear {
            DispatchQueue.main.async {
                rateLimits.usageUIActive = true
                Task { await rateLimits.refresh(force: false) }
            }
        }
        .onDisappear {
            rateLimits.usageUIActive = false
            expandedProvider = nil
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Data

    private var displayProviders: [ProviderRateLimits] {
        let order: [UsageProviderID] = [.claude, .codex, .grok]
        return order.map { id in
            if let existing = rateLimits.state.visibleProviders.first(where: { $0.provider == id }) {
                return existing
            }
            if let any = rateLimits.state.allProviders.first(where: { $0.provider == id }) {
                return any
            }
            return .placeholder(
                provider: id,
                status: rateLimits.isFetching ? .fetching : .unavailable,
                error: rateLimits.isFetching ? nil : L("Not signed in")
            )
        }
    }

    // MARK: - Compact list: mascot left, providers shifted right

    private func compactListWithMascot(providers: [ProviderRateLimits], size: CGSize) -> some View {
        let sidePad: CGFloat = 10
        let gap: CGFloat = 10
        // Square mascot fills most of the notch height
        let mascotSide = min(max(size.height - 16, 56), 120)

        return HStack(alignment: .center, spacing: gap) {
            UsageMascotView(side: mascotSide)
                .padding(.leading, sidePad)

            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    // Orca status-bar RefreshCw control (size 11 + spin while fetching)
                    UsageRefreshButton(isRefreshing: rateLimits.isFetching) {
                        Task { await rateLimits.refresh(force: true) }
                    }
                }
                .padding(.trailing, 4)
                .padding(.top, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(providers) { limits in
                            Button {
                                withAnimation(.smooth(duration: 0.22)) {
                                    expandedProvider = limits.provider
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    CompactProviderChip(
                                        limits: limits,
                                        now: now,
                                        isFetching: rateLimits.isFetching && limits.status == .fetching
                                    )
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.notch(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary.opacity(0.55))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, sidePad)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if rateLimits.isFetching {
                ProgressView().controlSize(.small)
                Text(L("Loading usage…"))
                    .font(.notch(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProviderIconView(provider: .claude, size: 16)
                    ProviderIconView(provider: .codex, size: 16)
                    ProviderIconView(provider: .grok, size: 16)
                }
                Text(L("No subscription usage yet"))
                    .font(.notch(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(L("Sign in to Claude, Codex, or Grok CLI. Manage agents in Settings → Usage."))
                    .font(.notch(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                HStack(spacing: 8) {
                    ForEach([UsageProviderID.claude, .codex, .grok], id: \.rawValue) { provider in
                        Button {
                            ProviderAuthService.beginSignIn(for: provider)
                        } label: {
                            HStack(spacing: 4) {
                                ProviderIconView(provider: provider, size: 11)
                                Text(provider.displayName)
                                    .font(.notch(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Left mascot (square, rounded like Orca)

struct UsageMascotView: View {
    var side: CGFloat = 72

    var body: some View {
        Group {
            if let img = OrcaIconLoader.image(names: ["usage_mascot", "UsageMascot"]) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
            } else if let asset = NSImage(named: "UsageMascot") {
                Image(nsImage: asset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "face.smiling")
                            .font(.notch(size: side * 0.35))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: max(6, side * 0.18), style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Compact chip (Orca status bar / Image #1)

/// [icon] [miniBar] 0% used 5h · 50% used 1d 23h · 84% used Fable
struct CompactProviderChip: View {
    let limits: ProviderRateLimits
    var now: Date
    var isFetching: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconView(provider: limits.provider, size: 13)
                .frame(width: 14, height: 14)

            if limits.status == .idle || (limits.status == .fetching && chips.isEmpty) {
                Text("···")
                    .font(.notch(size: 11))
                    .foregroundStyle(.secondary)
            } else if limits.status == .unavailable && chips.isEmpty {
                Text("--")
                    .font(.notch(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.55))
            } else if chips.isEmpty && limits.status == .error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.notch(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                // Mini-bar for primary window of ANY provider (session → weekly → monthly → fable)
                if let primary = primaryWindow {
                    CompactMiniBar(usedPercent: primary.usedPercent)
                }
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    if index > 0 {
                        Text("·")
                            .font(.notch(size: 11))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    Text(chip)
                        .font(.notch(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                if limits.status == .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.notch(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(isFetching ? 0.85 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// First available window drives the mini progress bar (all providers).
    private var primaryWindow: RateLimitWindow? {
        limits.session ?? limits.weekly ?? limits.monthly ?? limits.fableWeekly
    }

    private var chips: [String] {
        var out: [String] = []
        if let session = limits.session {
            let label = OrcaUsageFormatting.chipLabel(for: session, now: now, fable: false)
            out.append(OrcaUsageFormatting.percentUsedLabel(session.usedPercent, suffix: label))
        }
        if let weekly = limits.weekly {
            let label = OrcaUsageFormatting.chipLabel(for: weekly, now: now, fable: false)
            out.append(OrcaUsageFormatting.percentUsedLabel(weekly.usedPercent, suffix: label))
        }
        if let fable = limits.fableWeekly {
            out.append(OrcaUsageFormatting.percentUsedLabel(fable.usedPercent, suffix: "Fable"))
        }
        // Show monthly whenever present (Grok etc.), not only when alone
        if let monthly = limits.monthly {
            let label = OrcaUsageFormatting.chipLabel(for: monthly, now: now, fable: false)
            out.append(OrcaUsageFormatting.percentUsedLabel(monthly.usedPercent, suffix: label))
        }
        return out
    }
}

struct CompactMiniBar: View {
    let usedPercent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(OrcaUsageFormatting.barColor(usedPercent: usedPercent))
                    .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, usedPercent)) / 100)))
            }
        }
        .frame(width: 48, height: 6)
    }
}

// MARK: - Detail panel (Orca ProviderPanel / Image #2)

struct ProviderDetailPanel: View {
    let limits: ProviderRateLimits
    var now: Date
    var isFetching: Bool
    var onBack: () -> Void
    var onSignIn: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        GeometryReader { geo in
            // Match compact Usage list metrics (mascot + provider cards).
            let sidePad: CGFloat = 10
            let gap: CGFloat = 10
            let logoSide = min(max(geo.size.height - 16, 56), 120)

            HStack(alignment: .center, spacing: gap) {
                // Left: large square logo (UsageMascotView language)
                ProviderDetailLogoSquare(provider: limits.provider, side: logoSide)
                    .padding(.leading, sidePad)

                VStack(spacing: 0) {
                    // Top chrome — same as compact list (refresh top-right) + back
                    HStack(spacing: 8) {
                        Button(action: onBack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.notch(size: 11, weight: .semibold))
                                Text(L("Back"))
                                    .font(.notch(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        UsageRefreshButton(isRefreshing: isFetching, action: onRefresh)
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 2)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            // Title row — same type scale as compact chips
                            HStack(spacing: 6) {
                                Text(limits.provider.displayName)
                                    .font(.notch(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(updatedText)
                                    .font(.notch(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)

                            if limits.status == .unavailable
                                || (limits.status == .error && sections.isEmpty) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(limits.error ?? L("Unavailable"))
                                        .font(.notch(size: 11))
                                        .foregroundStyle(.secondary)
                                    Button(action: onSignIn) {
                                        HStack(spacing: 4) {
                                            ProviderIconView(provider: limits.provider, size: 11)
                                            Text(L("Sign in"))
                                                .font(.notch(size: 10, weight: .semibold))
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.white.opacity(0.12)))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.white.opacity(0.9))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                            } else {
                                // Same card stack as compact provider list
                                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                                    DetailUsageRow(
                                        label: section.label,
                                        window: section.window,
                                        now: now
                                    )
                                }
                            }

                            // Footer actions — list rows (project chrome), not pills
                            VStack(alignment: .leading, spacing: 0) {
                                Divider().overlay(Color.white.opacity(0.08))
                                    .padding(.top, 4)
                                detailRowButton(
                                    title: "\(limits.provider.displayName) \(L("Account"))",
                                    systemImage: nil
                                ) {
                                    ProviderAuthService.openAccountPage(for: limits.provider)
                                }
                                detailRowButton(
                                    title: L("Sign in / re-auth"),
                                    systemImage: "person.badge.key"
                                ) {
                                    onSignIn()
                                }
                            }
                        }
                        .padding(.trailing, sidePad)
                        .padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var updatedText: String {
        if limits.status == .fetching {
            return L("Updating…")
        }
        let date = Date(timeIntervalSince1970: TimeInterval(limits.updatedAt) / 1000)
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return L("Updated just now") }
        if seconds < 3600 {
            return String(format: L("Updated %dm ago"), Int(seconds / 60))
        }
        if seconds < 86_400 {
            return String(format: L("Updated %dh ago"), Int(seconds / 3600))
        }
        return L("Updated earlier")
    }

    private var sections: [(label: String, window: RateLimitWindow)] {
        var out: [(String, RateLimitWindow)] = []
        if let s = limits.session { out.append((L("Session"), s)) }
        if let w = limits.weekly { out.append((L("Weekly"), w)) }
        if let f = limits.fableWeekly { out.append((L("Fable"), f)) }
        if let m = limits.monthly { out.append((L("Monthly"), m)) }
        return out
    }

    private func detailRowButton(title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.notch(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.notch(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.notch(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

/// Large square provider mark — same visual language as `UsageMascotView`.
struct ProviderDetailLogoSquare: View {
    let provider: UsageProviderID
    var side: CGFloat = 88

    private var corner: CGFloat { max(6, side * 0.18) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(0.08))
            ProviderIconView(provider: provider, size: side * 0.62)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Compact usage row — same card chrome as compact provider list rows.
struct DetailUsageRow: View {
    let label: String
    let window: RateLimitWindow
    var now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.notch(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 54, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            // Mini-bar (same height/color language as CompactMiniBar)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(OrcaUsageFormatting.barColor(usedPercent: window.usedPercent))
                        .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, window.usedPercent)) / 100)))
                }
            }
            .frame(height: 6)

            Text(percentText)
                .font(.notch(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            if let reset = resetText {
                Text("·")
                    .font(.notch(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                Text(reset)
                    .font(.notch(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .contentShape(Rectangle())
    }

    private var percentText: String {
        "\(Int(min(100, max(0, window.usedPercent)).rounded()))%"
    }

    private var resetText: String? {
        guard let resetsAt = window.resetsAt else { return nil }
        let ms = Double(resetsAt) - now.timeIntervalSince1970 * 1000
        let duration = OrcaUsageFormatting.formatResetDuration(ms: ms)
        return duration
    }
}

// MARK: - Formatting (Orca parity)

enum OrcaUsageFormatting {
    static func percentUsedLabel(_ usedPercent: Double, suffix: String) -> String {
        let pct = Int(min(100, max(0, usedPercent)).rounded())
        if suffix.isEmpty { return "\(pct)% used" }
        return "\(pct)% used \(suffix)"
    }

    static func chipLabel(for window: RateLimitWindow, now: Date, fable: Bool) -> String {
        if fable { return "Fable" }
        if let resetsAt = window.resetsAt {
            let ms = Double(resetsAt) - now.timeIntervalSince1970 * 1000
            return formatResetDuration(ms: ms)
        }
        return formatWindowLabel(minutes: window.windowMinutes)
    }

    static func formatWindowLabel(minutes: Int) -> String {
        if minutes == 10_080 { return "wk" }
        if minutes == 300 { return "5h" }
        if minutes == 60 { return "1h" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes % (60 * 24 * 7) == 0 { return "\(minutes / (60 * 24 * 7))wk" }
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    static func formatResetDuration(ms: Double) -> String {
        if ms <= 0 { return "now" }
        let totalMins = Int(floor(ms / 60_000))
        if totalMins < 60 { return "\(totalMins)m" }
        let hours = totalMins / 60
        let mins = totalMins % 60
        if hours >= 24 {
            let days = hours / 24
            let remHours = hours % 24
            return remHours > 0 ? "\(days)d \(remHours)h" : "\(days)d"
        }
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }

    static func barColor(usedPercent: Double) -> Color {
        let u = min(100, max(0, usedPercent))
        if u < 60 { return Color(red: 0.22, green: 0.78, blue: 0.45) }
        if u < 80 { return Color(red: 0.92, green: 0.78, blue: 0.18) }
        return Color(red: 0.92, green: 0.28, blue: 0.28)
    }
}
