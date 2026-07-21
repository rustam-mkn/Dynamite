//
//  UsageSettingsView.swift
//  boringNotch — Settings pane: agent detection + usage providers + sign-in
//

import Defaults
import SwiftUI

struct UsageSettingsView: View {
    @Default(.usageTabEnabled) private var usageTabEnabled
    @ObservedObject private var agents = AgentDetectionService.shared
    @ObservedObject private var rateLimits = RateLimitService.shared
    @ObservedObject private var language = LanguageManager.shared
    @State private var signInMessage: String?

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .usageTabEnabled) {
                    Text(L("Enable Usage tab"))
                }
                Text(L("Shows subscription usage (Claude, Codex, Grok) in the notch. Agents installed on this Mac are detected automatically. Order and icon: Settings → Spaces."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("Usage"))
            }

            Section {
                HStack {
                    Text(L("Last usage refresh"))
                    Spacer()
                    if let at = rateLimits.lastRefreshAt {
                        Text(at, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                    if rateLimits.isFetching {
                        ProgressView().controlSize(.small)
                    }
                }
                Button {
                    Task { await rateLimits.refresh(force: true) }
                } label: {
                    Label(L("Refresh usage now"), systemImage: "arrow.clockwise")
                }
                .disabled(rateLimits.isFetching)

                ForEach(providerStatusRows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProviderIconView(provider: row.provider, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.body.weight(.medium))
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            statusBadge(row.status)
                        }
                        HStack(spacing: 8) {
                            if row.needsSignIn {
                                Button {
                                    signIn(row.provider)
                                } label: {
                                    Label(L("Sign in"), systemImage: "person.badge.key")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button {
                                    signIn(row.provider)
                                } label: {
                                    Label(L("Re-authenticate"), systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            if row.provider == .claude {
                                Button {
                                    syncClaudeOnly()
                                } label: {
                                    Label(L("Sync Claude session"), systemImage: "square.and.arrow.down.on.square")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(L("Already signed in via Claude CLI? Export Keychain session to a file Pocket can read (no password dialog)."))
                            }
                            Button {
                                ProviderAuthService.openAccountPage(for: row.provider)
                            } label: {
                                Label(L("Account page"), systemImage: "safari")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Text(ProviderAuthService.loginCommand(for: row.provider))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let signInMessage {
                    Text(signInMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Subscription usage"))
            } footer: {
                Text(L("Sign in opens the browser for the provider. Session files are updated in the background so Pocket can read usage (no Keychain password dialog). If you already signed in via CLI, use Sync Claude session, then Refresh usage."))
                    .font(.caption)
            }

            Section {
                HStack {
                    Text(L("Detected agents"))
                    Spacer()
                    Text("\(agents.installedAgents.count) / \(AgentCatalog.catalog.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if agents.isScanning {
                        ProgressView().controlSize(.small)
                    }
                }

                Button {
                    Task { await agents.refresh() }
                } label: {
                    Label(L("Rescan agents"), systemImage: "magnifyingglass")
                }
                .disabled(agents.isScanning)

                if let result = agents.result, !result.shellHydrationOk {
                    Text("\(L("Shell PATH hydration failed — using install-dir fallback.")) (\(result.pathFailureReason))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(agents.allAgents) { agent in
                    HStack(spacing: 8) {
                        AgentCatalogIcon(agentID: agent.id, size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.label)
                            Text(agent.cmd)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if agent.isInstalled {
                            Text(L("Installed"))
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text(L("Not found"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let url = URL(string: agent.homepageUrl) {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                }
            } header: {
                Text(L("Installed agents"))
            } footer: {
                Text(L("Detection matches Orca: PATH + nvm/volta/fnm/mise/pnpm/bun/Homebrew install dirs. Rescan reloads your login-shell PATH without restarting the app."))
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .id(language.revision)
        .onAppear {
            agents.start(scanImmediately: true)
            rateLimits.start(fetchImmediately: true)
        }
    }

    private func signIn(_ provider: UsageProviderID) {
        let ok = ProviderAuthService.beginSignIn(for: provider)
        if ok {
            signInMessage = L("Browser opened for sign-in. Usage refreshes automatically when login finishes.")
            scheduleUsagePolls()
        } else {
            signInMessage = L("Could not open the browser. Open the provider login page manually.")
            ProviderAuthService.openAccountPage(for: provider)
        }
    }

    private func syncClaudeOnly() {
        let ok = ProviderAuthService.syncClaudeCredentialsOnly()
        if ok {
            signInMessage = L("Exporting Claude session in the background. Return here after a few seconds.")
            scheduleUsagePolls()
        } else {
            signInMessage = L("Could not start credential export. Try Sign in again.")
        }
    }

    private func scheduleUsagePolls() {
        Task {
            // Wait for Terminal export / browser login; poll repeatedly.
            for delayMs in [3_000, 6_000, 10_000, 15_000, 25_000, 40_000, 60_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                await rateLimits.refresh(force: true)
                if rateLimits.state.claude?.status == .ok { break }
            }
        }
    }

    private struct ProviderStatusRow {
        var id: String
        var provider: UsageProviderID
        var name: String
        var detail: String
        var status: ProviderRateLimitStatus
        var needsSignIn: Bool
    }

    private var providerStatusRows: [ProviderStatusRow] {
        func row(_ limits: ProviderRateLimits?, id: UsageProviderID, fallbackUnavailable: String) -> ProviderStatusRow {
            if let limits {
                let detail: String
                switch limits.status {
                case .ok:
                    let parts = [
                        limits.session.map { "5h \(Int($0.usedPercent.rounded()))%" },
                        limits.weekly.map { "wk \(Int($0.usedPercent.rounded()))%" },
                        limits.monthly.map { "mo \(Int($0.usedPercent.rounded()))%" },
                        limits.fableWeekly.map { "Fable \(Int($0.usedPercent.rounded()))%" }
                    ].compactMap { $0 }
                    detail = parts.isEmpty ? L("Connected") : parts.joined(separator: " · ")
                case .fetching:
                    detail = L("Refreshing…")
                case .error:
                    detail = limits.error ?? L("Error")
                case .unavailable:
                    detail = limits.error ?? fallbackUnavailable
                case .idle:
                    detail = L("Idle")
                }
                let needs = limits.status == .unavailable || limits.status == .error
                return ProviderStatusRow(
                    id: id.rawValue,
                    provider: id,
                    name: id.displayName,
                    detail: detail,
                    status: limits.status,
                    needsSignIn: needs
                )
            }
            return ProviderStatusRow(
                id: id.rawValue,
                provider: id,
                name: id.displayName,
                detail: fallbackUnavailable,
                status: .unavailable,
                needsSignIn: true
            )
        }

        return [
            row(rateLimits.state.claude, id: .claude, fallbackUnavailable: L("Not signed in")),
            row(rateLimits.state.codex, id: .codex, fallbackUnavailable: L("Not signed in")),
            row(rateLimits.state.grok, id: .grok, fallbackUnavailable: L("Not signed in"))
        ]
    }

    @ViewBuilder
    private func statusBadge(_ status: ProviderRateLimitStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .ok: return (L("OK"), .green)
            case .fetching: return (L("…"), .secondary)
            case .error: return (L("Error"), .orange)
            case .unavailable: return (L("—"), .secondary)
            case .idle: return (L("Idle"), .secondary)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

