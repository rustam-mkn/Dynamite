//
//  RateLimitTypes.swift
//  boringNotch — ported from Orca src/shared/rate-limit-types.ts
//

import Foundation
import SwiftUI

struct RateLimitWindow: Equatable, Sendable, Codable {
    /// Percentage of the window consumed (0–100).
    var usedPercent: Double
    /// Window duration in minutes: 300 (5h) or 10080 (7d).
    var windowMinutes: Int
    /// Unix ms timestamp when the window resets, if known.
    var resetsAt: Int64?
    /// Human-readable reset description, e.g. "2:30 PM" or "Thu".
    var resetDescription: String?
}

enum ProviderRateLimitStatus: String, Equatable, Sendable, Codable {
    case idle
    case fetching
    case ok
    case error
    case unavailable
}

struct RateLimitBucket: Equatable, Sendable, Codable {
    var name: String
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Int64?
    var resetDescription: String?

    var asWindow: RateLimitWindow {
        RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription
        )
    }
}

enum UsageRateLimitSource: String, Equatable, Sendable, Codable {
    case oauth
    case cli
    case web
}

enum UsageRateLimitFailureKind: String, Equatable, Sendable, Codable {
    case missingCredentials = "missing-credentials"
    case staleToken = "stale-token"
    case refreshableCredentialsWithoutToken = "refreshable-credentials-without-token"
    case delegatedRefreshRequired = "delegated-refresh-required"
    case deferredByLiveSession = "deferred-by-live-session"
    case keychainUnavailable = "keychain-unavailable"
    case missingScope = "missing-scope"
    case network
    case server
    case parse
    case rateLimited = "rate-limited"
    case cliUnavailable = "cli-unavailable"
    case usageUnavailable = "usage-unavailable"
    case unknown
}

struct UsageRateLimitMetadata: Equatable, Sendable, Codable {
    var source: UsageRateLimitSource?
    var attemptedSources: [UsageRateLimitSource]?
    var failureKind: UsageRateLimitFailureKind?
    var credentialSource: String?
    var authProvenance: String?
    var deferredByLiveClaudeSession: Bool?
    var lastSuccessfulSource: UsageRateLimitSource?
}

enum UsageProviderID: String, CaseIterable, Identifiable, Sendable, Codable {
    case claude
    case codex
    case gemini
    case opencodeGo = "opencode-go"
    case kimi
    case minimax
    case grok
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .opencodeGo: return "OpenCode Go"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        }
    }

    /// SF Symbol used when no custom logo asset is available.
    var systemImage: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex: return "terminal"
        case .gemini: return "sparkles"
        case .opencodeGo: return "chevron.left.forwardslash.chevron.right"
        case .kimi: return "moon.stars"
        case .minimax: return "waveform"
        case .grok: return "x.circle"
        case .antigravity: return "atom"
        }
    }
}

struct ProviderRateLimits: Equatable, Sendable, Identifiable, Codable {
    var provider: UsageProviderID
    var session: RateLimitWindow?
    var weekly: RateLimitWindow?
    var fableWeekly: RateLimitWindow?
    var monthly: RateLimitWindow?
    var buckets: [RateLimitBucket]?
    var updatedAt: Int64
    var error: String?
    var status: ProviderRateLimitStatus
    var usageMetadata: UsageRateLimitMetadata?

    var id: String { provider.rawValue }

    var hasUsableWindows: Bool {
        session != nil || weekly != nil || monthly != nil || fableWeekly != nil
            || (buckets?.isEmpty == false)
    }

    static func placeholder(
        provider: UsageProviderID,
        status: ProviderRateLimitStatus,
        error: String? = nil
    ) -> ProviderRateLimits {
        ProviderRateLimits(
            provider: provider,
            session: nil,
            weekly: nil,
            fableWeekly: nil,
            monthly: nil,
            buckets: nil,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            error: error,
            status: status,
            usageMetadata: nil
        )
    }
}

struct RateLimitState: Equatable, Sendable, Codable {
    var claude: ProviderRateLimits?
    var codex: ProviderRateLimits?
    var gemini: ProviderRateLimits?
    var opencodeGo: ProviderRateLimits?
    var kimi: ProviderRateLimits?
    var antigravity: ProviderRateLimits?
    var minimax: ProviderRateLimits?
    var grok: ProviderRateLimits?
    var grokAuthConfigured: Bool
    var minimaxCookieConfigured: Bool

    static let empty = RateLimitState(
        claude: nil,
        codex: nil,
        gemini: nil,
        opencodeGo: nil,
        kimi: nil,
        antigravity: nil,
        minimax: nil,
        grok: nil,
        grokAuthConfigured: false,
        minimaxCookieConfigured: false
    )

    var allProviders: [ProviderRateLimits] {
        [claude, codex, gemini, opencodeGo, kimi, antigravity, minimax, grok].compactMap { $0 }
    }

    /// Providers that should appear in the notch (ok / fetching / error with data / configured).
    var visibleProviders: [ProviderRateLimits] {
        allProviders.filter { limits in
            switch limits.status {
            case .ok, .fetching, .error:
                return true
            case .unavailable, .idle:
                return limits.session != nil || limits.weekly != nil || limits.monthly != nil
            }
        }
    }
}

enum RateLimitFormatting {
    static func parseResetTimestamp(_ value: Any?) -> Int64? {
        if let number = value as? Double {
            guard number.isFinite else { return nil }
            return Int64(number > 10_000_000_000 ? number : number * 1000)
        }
        if let number = value as? Int {
            let d = Double(number)
            return Int64(d > 10_000_000_000 ? d : d * 1000)
        }
        if let number = value as? Int64 {
            return number > 10_000_000_000 ? number : number * 1000
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let numeric = Double(trimmed), numeric.isFinite {
                return Int64(numeric > 10_000_000_000 ? numeric : numeric * 1000)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: trimmed) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
            if let date = ISO8601DateFormatter().date(from: trimmed) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    static func resetDescription(fromMs ms: Int64?) -> String? {
        guard let ms else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("E HH:mm")
        return f.string(from: date)
    }

    static func resetDescription(fromISO iso: String?) -> String? {
        guard let iso, let ms = parseResetTimestamp(iso) else { return nil }
        return resetDescription(fromMs: ms)
    }

    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10_080: return "wk"
        case 43_200: return "mo"
        default:
            if minutes % (24 * 60) == 0 {
                return "\(minutes / (24 * 60))d"
            }
            if minutes % 60 == 0 {
                return "\(minutes / 60)h"
            }
            return "\(minutes)m"
        }
    }

    static func barColor(usedPercent: Double) -> Color {
        // Match Orca status-bar urgency colors
        if usedPercent < 60 { return Color(red: 0.22, green: 0.78, blue: 0.45) }
        if usedPercent < 80 { return Color(red: 0.92, green: 0.78, blue: 0.18) }
        return Color(red: 0.92, green: 0.28, blue: 0.28)
    }
}
