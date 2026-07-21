//
//  RateLimitService.swift
//  boringNotch — continuous rate-limit polling ported from Orca rate-limits/service.ts
//
//  Sticky providers: once a provider has been signed-in / shown usage, it never
//  hard-flips to "Not signed in" on transient errors or stale mirror files.
//

import AppKit
import Combine
import Defaults
import Foundation

extension Defaults.Keys {
    /// Providers that have successfully loaded at least once (or have credentials on disk).
    static let stickyUsageProviders = Key<Set<String>>("stickyUsageProviders", default: [])
}

@MainActor
final class RateLimitService: ObservableObject {
    static let shared = RateLimitService()

    @Published private(set) var state: RateLimitState = .empty
    @Published private(set) var isFetching = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?

    @Published var usageUIActive = false {
        didSet {
            if usageUIActive != oldValue {
                restartTimer()
                if usageUIActive {
                    Task { await refreshIfNeeded(force: false) }
                }
            }
        }
    }

    private let defaultPollMs: TimeInterval = 15 * 60
    private let activePollMs: TimeInterval = 60
    private let minRefetchMs: TimeInterval = 30
    /// Keep last-good usage numbers for a week on errors / unavailable.
    private let staleThresholdMs: TimeInterval = 7 * 24 * 60 * 60
    private let softErrorKeepOkMs: TimeInterval = 24 * 60 * 60

    private let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("boringNotch/UsageAuth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-usage-state.json")
    }()

    private var pollTimer: Timer?
    private var currentToken: CancellationToken?
    private var lastFetchStartedAt: Date?
    private var started = false

    private init() {
        if let cached = Self.loadCachedState(from: cacheURL) {
            state = cached
            markSticky(from: cached)
        }
    }

    func start(fetchImmediately: Bool = true) {
        guard !started else {
            if fetchImmediately {
                Task { await refresh(force: true) }
            }
            return
        }
        started = true
        // Bootstrap MUST finish before first fetch so we don't read a stale container.
        Task {
            await Task.detached(priority: .utility) {
                Self.bootstrapCredentialMirrors()
            }.value
            if fetchImmediately {
                await refresh(force: true)
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await refresh(force: true)
            }
        }
        restartTimer()

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshIfNeeded(force: false)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentToken?.cancel()
        currentToken = nil
        started = false
    }

    func refresh(force: Bool = true) async {
        await refreshIfNeeded(force: force)
    }

    private func refreshIfNeeded(force: Bool) async {
        if isFetching { return }
        if !force, let last = lastFetchStartedAt,
           Date().timeIntervalSince(last) < minRefetchMs {
            return
        }

        isFetching = true
        lastFetchStartedAt = Date()
        let token = CancellationToken()
        currentToken = token
        markFetching()

        let (claudeResult, codexResult, grokResult, grokConfigured) = await Task.detached(priority: .utility) {
            async let claude = ClaudeUsageFetcher.fetch(signal: token)
            async let codex = CodexUsageFetcher.fetch(signal: token)
            async let grok = GrokUsageFetcher.fetch(signal: token)
            let c = await claude
            let x = await codex
            let g = await grok
            let configured = GrokUsageFetcher.isAuthConfigured()
            return (c, x, g, configured)
        }.value

        if token.isCancelled {
            isFetching = false
            return
        }

        let mergedClaude = merge(previous: state.claude, next: claudeResult)
        let mergedCodex = merge(previous: state.codex, next: codexResult)
        let mergedGrok = merge(previous: state.grok, next: grokResult)

        if mergedClaude.status == .ok { stick(.claude) }
        if mergedCodex.status == .ok { stick(.codex) }
        if mergedGrok.status == .ok || grokConfigured { stick(.grok) }
        if ClaudeUsageFetcher.hasStoredCredentials() { stick(.claude) }
        if GrokUsageFetcher.hasStoredCredentials() { stick(.grok) }

        state = RateLimitState(
            claude: mergedClaude,
            codex: mergedCodex,
            gemini: state.gemini,
            opencodeGo: state.opencodeGo,
            kimi: state.kimi,
            antigravity: state.antigravity,
            minimax: state.minimax,
            grok: mergedGrok,
            grokAuthConfigured: grokConfigured || state.grokAuthConfigured || isSticky(.grok),
            minimaxCookieConfigured: false
        )
        lastRefreshAt = Date()
        isFetching = false
        currentToken = nil
        persistState()

        lastError = [claudeResult, codexResult, grokResult]
            .filter { $0.status == .error }
            .compactMap(\.error)
            .first
    }

    /// Prefer last-good provider data over "signed out" / transient errors.
    /// Sticky providers with credentials NEVER become hard `.unavailable`.
    private func merge(previous: ProviderRateLimits?, next: ProviderRateLimits) -> ProviderRateLimits {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let staleCutoff = staleThresholdMs * 1000
        let softOkCutoff = softErrorKeepOkMs * 1000
        let sticky = isSticky(next.provider) || hasCredentials(next.provider)

        if next.status == .ok {
            return next
        }

        if next.status == .unavailable {
            if let previous, previous.hasUsableWindows,
               nowMs - Double(previous.updatedAt) < staleCutoff {
                var kept = previous
                kept.status = .ok
                kept.error = nil
                return kept
            }
            if sticky {
                if let previous, previous.hasUsableWindows {
                    var kept = previous
                    kept.status = .error
                    kept.error = next.error ?? "Temporarily unavailable"
                    return kept
                }
                // Credentials exist but no prior windows — keep slot as error, not signed-out.
                return .placeholder(
                    provider: next.provider,
                    status: .error,
                    error: next.error ?? "Session temporarily unavailable"
                )
            }
            return next
        }

        if next.status == .error {
            if let previous, previous.hasUsableWindows {
                var kept = previous
                kept.error = next.error
                let age = nowMs - Double(previous.updatedAt)
                if (previous.status == .ok || sticky) && age < softOkCutoff {
                    kept.status = .ok
                } else {
                    kept.status = .error
                }
                return kept
            }
            if sticky {
                // Keep sticky provider visible even without prior windows.
                return next
            }
        }

        return next
    }

    private func hasCredentials(_ provider: UsageProviderID) -> Bool {
        switch provider {
        case .claude: return ClaudeUsageFetcher.hasStoredCredentials()
        case .grok: return GrokUsageFetcher.hasStoredCredentials()
        case .codex:
            return UsagePaths.newestExistingData(among: [
                UsagePaths.codexAuthFile,
                UsagePaths.pocketCodexAuthFile,
                UsagePaths.containerCodexAuthFile
            ]) != nil
        default: return false
        }
    }

    private func isSticky(_ provider: UsageProviderID) -> Bool {
        Defaults[.stickyUsageProviders].contains(provider.rawValue)
    }

    private func stick(_ provider: UsageProviderID) {
        var set = Defaults[.stickyUsageProviders]
        if set.insert(provider.rawValue).inserted {
            Defaults[.stickyUsageProviders] = set
        }
    }

    private func markSticky(from state: RateLimitState) {
        if state.claude?.hasUsableWindows == true { stick(.claude) }
        if state.codex?.hasUsableWindows == true { stick(.codex) }
        if state.grok?.hasUsableWindows == true || state.grokAuthConfigured { stick(.grok) }
    }

    private func markFetching() {
        func mark(_ p: ProviderRateLimits?) -> ProviderRateLimits? {
            guard var p else { return nil }
            if p.status == .ok || p.status == .error {
                p.status = .fetching
            }
            return p
        }
        state = RateLimitState(
            claude: mark(state.claude),
            codex: mark(state.codex),
            gemini: mark(state.gemini),
            opencodeGo: mark(state.opencodeGo),
            kimi: mark(state.kimi),
            antigravity: mark(state.antigravity),
            minimax: mark(state.minimax),
            grok: mark(state.grok),
            grokAuthConfigured: state.grokAuthConfigured,
            minimaxCookieConfigured: state.minimaxCookieConfigured
        )
    }

    private func restartTimer() {
        pollTimer?.invalidate()
        let interval = usageUIActive ? activePollMs : defaultPollMs
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Disk cache

    private func persistState() {
        var snapshot = state
        func scrub(_ p: ProviderRateLimits?) -> ProviderRateLimits? {
            guard var p, p.hasUsableWindows else { return nil }
            if p.status == .fetching || p.status == .error {
                p.status = .ok
                p.error = nil
            }
            return p
        }
        snapshot.claude = scrub(snapshot.claude)
        snapshot.codex = scrub(snapshot.codex)
        snapshot.grok = scrub(snapshot.grok)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {}
    }

    private static func loadCachedState(from url: URL) -> RateLimitState? {
        guard let data = try? Data(contentsOf: url),
              var state = try? JSONDecoder().decode(RateLimitState.self, from: data) else {
            return nil
        }
        let maxAgeMs: Double = 30 * 24 * 60 * 60 * 1000 // 30 days
        let now = Date().timeIntervalSince1970 * 1000
        func ageFilter(_ p: ProviderRateLimits?) -> ProviderRateLimits? {
            guard let p, p.hasUsableWindows else { return nil }
            guard now - Double(p.updatedAt) < maxAgeMs else { return nil }
            var kept = p
            if kept.status == .fetching || kept.status == .error {
                kept.status = .ok
                kept.error = nil
            }
            return kept
        }
        state.claude = ageFilter(state.claude)
        state.codex = ageFilter(state.codex)
        state.grok = ageFilter(state.grok)
        return state
    }

    /// Copy real-home CLI auth files into the sandbox container — only if source is newer.
    nonisolated private static func bootstrapCredentialMirrors() {
        UsagePaths.ensureUsageAuthDirectories()
        let pairs: [(String, String)] = [
            (UsagePaths.claudeCredentialsFile, UsagePaths.containerClaudeCredentialsFile),
            (UsagePaths.pocketClaudeCredentialsFile, UsagePaths.containerClaudeCredentialsFile),
            (UsagePaths.codexAuthFile, UsagePaths.containerCodexAuthFile),
            (UsagePaths.pocketCodexAuthFile, UsagePaths.containerCodexAuthFile),
            // Grok: CLI home first so container never stays on an expired token.
            (UsagePaths.grokAuthFile, UsagePaths.containerGrokAuthFile),
            (UsagePaths.pocketGrokAuthFile, UsagePaths.containerGrokAuthFile),
            (UsagePaths.grokAuthFile, UsagePaths.pocketGrokAuthFile)
        ]
        let fm = FileManager.default
        for (source, dest) in pairs {
            guard fm.fileExists(atPath: source),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: source)),
                  !data.isEmpty else { continue }
            let srcDate = (try? fm.attributesOfItem(atPath: source)[.modificationDate] as? Date) ?? .distantPast
            let dstDate = (try? fm.attributesOfItem(atPath: dest)[.modificationDate] as? Date) ?? .distantPast
            // Only promote when source is strictly newer (or dest missing).
            if !fm.fileExists(atPath: dest) || srcDate > dstDate {
                let dir = (dest as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: dest), options: [.atomic])
                try? fm.setAttributes(
                    [.posixPermissions: 0o600, .modificationDate: srcDate],
                    ofItemAtPath: dest
                )
            }
        }
    }
}
