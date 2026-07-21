//
//  ClaudeUsageFetcher.swift
//  boringNotch — Claude OAuth usage from credential files + automatic token refresh.
//  Ported from Orca rate-limits/claude-fetcher.ts (OAuth path) + oauth-refresh.ts.
//
//  Never uses Security.framework / SecItem (that shows TheBoringNotch keychain UI).
//  Credentials are read from exported files and refreshed in-process so Anthropic
//  does not "drop" when access tokens expire.
//

import Foundation

enum ClaudeUsageFetcher {
    private static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let oauthBetaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-code/2.1.0"
    private static let apiTimeout: TimeInterval = 10

    /// True when we have a usable access token and/or refresh token on disk.
    static func hasStoredCredentials() -> Bool {
        let creds = readFromCredentialsFile()
        return creds.token != nil || creds.hasRefreshableCredentials
    }

    static func fetch(signal: CancellationToken? = nil) async -> ProviderRateLimits {
        if signal?.isCancelled == true {
            return .placeholder(provider: .claude, status: .error, error: "Rate-limit fetch aborted")
        }

        var creds = await loadCredentialsWithRefresh(signal: signal)
        guard let token = creds.token else {
            if creds.hasRefreshableCredentials {
                return .placeholder(
                    provider: .claude,
                    status: .error,
                    error: "Claude credentials need refresh — use Sign in"
                )
            }
            return .placeholder(
                provider: .claude,
                status: .unavailable,
                error: "Not signed in — use Sign in (exports Claude session for Pocket)"
            )
        }

        let first = await fetchUsage(token: token, signal: signal, source: creds.source)
        // On auth failure, refresh once and retry (covers expired access tokens).
        if first.needsAuthRetry, creds.hasRefreshableCredentials {
            if let refreshed = await forceRefreshStoredCredentials() {
                creds = refreshed
                if let newToken = refreshed.token {
                    return await fetchUsage(token: newToken, signal: signal, source: refreshed.source)
                        .asProviderRateLimits(source: refreshed.source)
                }
            }
        }
        return first.asProviderRateLimits(source: creds.source)
    }

    // MARK: - Credentials

    private struct OAuthCredResult {
        var token: String?
        var hasRefreshableCredentials: Bool
        var source: String
        var rawJSON: String?
    }

    private struct UsageFetchResult {
        var needsAuthRetry: Bool
        var limits: ProviderRateLimits

        func asProviderRateLimits(source: String) -> ProviderRateLimits {
            var out = limits
            if out.usageMetadata == nil {
                out.usageMetadata = UsageRateLimitMetadata()
            }
            out.usageMetadata?.credentialSource = source
            out.usageMetadata?.source = .oauth
            out.usageMetadata?.attemptedSources = [.oauth]
            return out
        }
    }

    /// Load credentials, proactively refresh when near expiry, persist rotated tokens.
    private static func loadCredentialsWithRefresh(signal: CancellationToken?) async -> OAuthCredResult {
        var creds = readFromCredentialsFile()
        guard let raw = creds.rawJSON else { return creds }

        let shouldRefresh = ClaudeOAuthRefresh.isAccessTokenExpiring(credentialsJSON: raw)
            || creds.token == nil
        guard shouldRefresh, creds.hasRefreshableCredentials else {
            // Mirror whatever we have into container so restarts stay signed-in.
            if let raw = creds.rawJSON {
                persistCredentialsJSON(raw)
            }
            return creds
        }

        if signal?.isCancelled == true { return creds }

        if let refreshedJSON = await ClaudeOAuthRefresh.refresh(credentialsJSON: raw) {
            persistCredentialsJSON(refreshedJSON)
            return parseOAuthCredentialsJSON(refreshedJSON, source: "oauth-refresh")
        }
        return creds
    }

    private static func forceRefreshStoredCredentials() async -> OAuthCredResult? {
        guard let raw = readFromCredentialsFile().rawJSON,
              let refreshedJSON = await ClaudeOAuthRefresh.refresh(credentialsJSON: raw) else {
            return nil
        }
        persistCredentialsJSON(refreshedJSON)
        return parseOAuthCredentialsJSON(refreshedJSON, source: "oauth-refresh-retry")
    }

    private static func persistCredentialsJSON(_ json: String) {
        // Container (always writable) + real-home pocket + ~/.claude (best-effort).
        _ = UsagePaths.persistAuthJSON(
            json,
            containerPath: UsagePaths.containerClaudeCredentialsFile,
            homePath: UsagePaths.pocketClaudeCredentialsFile
        )
        // Best-effort CLI path so `claude` CLI and Pocket stay in sync after refresh.
        let cliPath = UsagePaths.claudeCredentialsFile
        if cliPath != UsagePaths.pocketClaudeCredentialsFile {
            let data = Data(json.utf8)
            try? FileManager.default.createDirectory(
                atPath: (cliPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? data.write(to: URL(fileURLWithPath: cliPath), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cliPath)
        }
    }

    private static func readFromCredentialsFile() -> OAuthCredResult {
        // Prefer freshest file by mtime among candidates with a valid token/refresh.
        var best: OAuthCredResult?
        var bestDate: Date = .distantPast
        let fm = FileManager.default

        for path in credentialsFileCandidates() {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let parsed = parseOAuthCredentialsJSON(raw, source: path)
            guard parsed.token != nil || parsed.hasRefreshableCredentials else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime >= bestDate {
                best = parsed
                bestDate = mtime
            }
        }
        return best ?? OAuthCredResult(token: nil, hasRefreshableCredentials: false, source: "none", rawJSON: nil)
    }

    private static func credentialsFileCandidates() -> [String] {
        var paths: [String] = [
            // All mirrors; readFromCredentialsFile picks the freshest by mtime.
            UsagePaths.claudeCredentialsFile,
            UsagePaths.pocketClaudeCredentialsFile,
            UsagePaths.containerClaudeCredentialsFile
        ]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            paths.append((env as NSString).appendingPathComponent(".credentials.json"))
        }
        paths.append(UsagePaths.underHome("Library", "Application Support", "Claude", ".credentials.json"))
        // Dedup while preserving order
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func parseOAuthCredentialsJSON(_ raw: String, source: String) -> OAuthCredResult {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OAuthCredResult(token: nil, hasRefreshableCredentials: false, source: "none", rawJSON: nil)
        }
        let oauth = (json["claudeAiOauth"] as? [String: Any])
            ?? (json["claude_ai_oauth"] as? [String: Any])
        let token = (oauth?["accessToken"] as? String) ?? (oauth?["access_token"] as? String)
        let refresh = (oauth?["refreshToken"] as? String) ?? (oauth?["refresh_token"] as? String)
        let hasRefresh = (refresh?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if let token, !token.isEmpty {
            return OAuthCredResult(token: token, hasRefreshableCredentials: hasRefresh, source: source, rawJSON: raw)
        }
        return OAuthCredResult(token: nil, hasRefreshableCredentials: hasRefresh, source: source, rawJSON: hasRefresh ? raw : nil)
    }

    // MARK: - Usage API

    private static func fetchUsage(token: String, signal: CancellationToken?, source: String) async -> UsageFetchResult {
        do {
            var request = URLRequest(url: oauthUsageURL, timeoutInterval: apiTimeout)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if signal?.isCancelled == true {
                return UsageFetchResult(
                    needsAuthRetry: false,
                    limits: .placeholder(provider: .claude, status: .error, error: "Rate-limit fetch aborted")
                )
            }
            guard let http = response as? HTTPURLResponse else {
                return UsageFetchResult(
                    needsAuthRetry: false,
                    limits: .placeholder(provider: .claude, status: .error, error: "Invalid response")
                )
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return UsageFetchResult(
                    needsAuthRetry: true,
                    limits: .placeholder(
                        provider: .claude,
                        status: .error,
                        error: "Claude session expired — refreshing…"
                    )
                )
            }
            guard http.statusCode == 200 else {
                return UsageFetchResult(
                    needsAuthRetry: false,
                    limits: .placeholder(
                        provider: .claude,
                        status: .error,
                        error: "Claude usage request failed (HTTP \(http.statusCode))"
                    )
                )
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return UsageFetchResult(
                    needsAuthRetry: false,
                    limits: .placeholder(provider: .claude, status: .error, error: "Failed to parse Claude usage")
                )
            }

            let session = mapWindow(json["five_hour"] as? [String: Any], windowMinutes: 300)
            let weekly = mapWindow(json["seven_day"] as? [String: Any], windowMinutes: 10_080)
            let fable = mapFableWeeklyWindow(json)

            var meta = UsageRateLimitMetadata()
            meta.source = .oauth
            meta.credentialSource = source
            meta.attemptedSources = [.oauth]
            meta.lastSuccessfulSource = .oauth

            let limits = ProviderRateLimits(
                provider: .claude,
                session: session,
                weekly: weekly,
                fableWeekly: fable,
                monthly: nil,
                buckets: nil,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                error: nil,
                status: .ok,
                usageMetadata: meta
            )
            return UsageFetchResult(needsAuthRetry: false, limits: limits)
        } catch {
            if signal?.isCancelled == true {
                return UsageFetchResult(
                    needsAuthRetry: false,
                    limits: .placeholder(provider: .claude, status: .error, error: "Rate-limit fetch aborted")
                )
            }
            return UsageFetchResult(
                needsAuthRetry: false,
                limits: .placeholder(
                    provider: .claude,
                    status: .error,
                    error: error.localizedDescription
                )
            )
        }
    }

    // MARK: - Window mapping

    private static func mapWindow(_ raw: [String: Any]?, windowMinutes: Int) -> RateLimitWindow? {
        guard let raw else { return nil }
        let used: Double?
        if let u = raw["utilization"] as? Double {
            used = u
        } else if let u = raw["utilization"] as? Int {
            used = Double(u)
        } else if let u = raw["used_percentage"] as? Double {
            used = u
        } else if let u = raw["used_percentage"] as? Int {
            used = Double(u)
        } else {
            used = nil
        }
        guard let usedPercent = used else { return nil }
        let resetsAt = RateLimitFormatting.parseResetTimestamp(raw["resets_at"])
        return RateLimitWindow(
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: RateLimitFormatting.resetDescription(fromMs: resetsAt)
        )
    }

    private static func mapFableWeeklyWindow(_ data: [String: Any]) -> RateLimitWindow? {
        if let limits = data["limits"] as? [[String: Any]] {
            let fable = limits.first { limit in
                guard (limit["kind"] as? String) == "weekly_scoped" else { return false }
                let hasPercent = limit["percent"] is Double || limit["percent"] is Int
                guard hasPercent else { return false }
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return name == "fable"
            }
            if let fable {
                let percent: Double
                if let p = fable["percent"] as? Double { percent = p }
                else if let p = fable["percent"] as? Int { percent = Double(p) }
                else { percent = 0 }
                let resetsAt = RateLimitFormatting.parseResetTimestamp(fable["resets_at"])
                return RateLimitWindow(
                    usedPercent: min(100, max(0, percent)),
                    windowMinutes: 10_080,
                    resetsAt: resetsAt,
                    resetDescription: RateLimitFormatting.resetDescription(fromMs: resetsAt)
                )
            }
        }
        return mapWindow(data["fable_weekly"] as? [String: Any], windowMinutes: 10_080)
            ?? mapWindow(data["fable_seven_day"] as? [String: Any], windowMinutes: 10_080)
            ?? mapWindow(data["seven_day_fable"] as? [String: Any], windowMinutes: 10_080)
    }
}

/// Simple cancellation flag for fetch cycles.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }
}
