//
//  GrokUsageFetcher.swift
//  boringNotch — Grok billing/usage + durable OIDC refresh
//
//  Critical: never let a stale container mirror shadow a fresher ~/.grok/auth.json.
//  Always pick the best session across all candidates, refresh when near expiry,
//  and persist rotated tokens to every known path.
//

import Foundation

enum GrokUsageFetcher {
    private static let preferredIssuer = "https://auth.x.ai"
    private static let billingCreditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let billingDefaultURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let apiTimeout: TimeInterval = 15
    private static let weeklyMinutes = 10_080
    private static let monthlyMinutes = 43_200
    private static let authHeader = "xai-grok-cli"

    struct GrokAuthSession {
        var accessToken: String
        var userId: String?
        var email: String?
        var teamId: String?
        var expiresAtMs: Int64?
        var sourcePath: String
        var mapKey: String
        var refreshToken: String?
        var oidcIssuer: String
        var oidcClientId: String?
        var rawEntry: [String: Any]
        var fullFileJSON: [String: Any]
    }

    enum AuthRead {
        case missing
        case error(String)
        case ok(GrokAuthSession)
    }

    static func hasStoredCredentials() -> Bool {
        if case .ok = readAuthSession() { return true }
        return authFileCandidates().contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func readAuthSession() -> AuthRead {
        let candidates = authFileCandidates()
        let fm = FileManager.default
        var best: GrokAuthSession?
        var bestScore: Int64 = .min

        for path in candidates {
            guard fm.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let mtimeMs = Int64(
                ((try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                    ?? .distantPast).timeIntervalSince1970 * 1000
            )
            for (key, value) in json {
                guard let entry = value as? [String: Any],
                      let token = entry["key"] as? String,
                      !token.isEmpty else { continue }

                let expiresAtMs = RateLimitFormatting.parseResetTimestamp(entry["expires_at"])
                let isPreferred = key == preferredIssuer || key.hasPrefix("\(preferredIssuer)::")
                // Score: prefer non-expired, preferred issuer, later expiry, newer file.
                var score: Int64 = mtimeMs / 1000
                if isPreferred { score += 1_000_000_000 }
                if let exp = expiresAtMs {
                    score += exp / 1000
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    if exp > now { score += 5_000_000_000 }
                } else {
                    score += 2_000_000_000 // unknown expiry still usable
                }

                let session = GrokAuthSession(
                    accessToken: token,
                    userId: entry["user_id"] as? String,
                    email: entry["email"] as? String,
                    teamId: entry["team_id"] as? String,
                    expiresAtMs: expiresAtMs,
                    sourcePath: path,
                    mapKey: key,
                    refreshToken: entry["refresh_token"] as? String,
                    oidcIssuer: (entry["oidc_issuer"] as? String) ?? preferredIssuer,
                    oidcClientId: (entry["oidc_client_id"] as? String)
                        ?? key.split(separator: ":").last.map(String.init),
                    rawEntry: entry,
                    fullFileJSON: json
                )
                if best == nil || score > bestScore {
                    best = session
                    bestScore = score
                }
            }
        }

        guard let best else { return .missing }
        return .ok(best)
    }

    static func isAuthConfigured() -> Bool {
        hasStoredCredentials()
    }

    static func fetch(signal: CancellationToken? = nil) async -> ProviderRateLimits {
        if signal?.isCancelled == true {
            return .placeholder(provider: .grok, status: .error, error: "Rate-limit fetch aborted")
        }

        switch await loadSessionWithRefresh(signal: signal) {
        case .missing:
            return .placeholder(provider: .grok, status: .unavailable, error: "Not signed in to Grok — use Sign in")
        case .error(let message):
            return .placeholder(provider: .grok, status: .error, error: message)
        case .ok(let session):
            let result = await fetchBilling(session: session, signal: signal)
            // On 401, force one OIDC refresh + retry (covers clock skew / early revoke).
            if result.status == .error,
               (result.error?.contains("401") == true
                || result.error?.contains("403") == true
                || result.error?.localizedCaseInsensitiveContains("expired") == true),
               session.refreshToken != nil {
                if let refreshed = await forceRefresh(session: session) {
                    return await fetchBilling(session: refreshed, signal: signal)
                }
            }
            return result
        }
    }

    // MARK: - Refresh

    private static func loadSessionWithRefresh(signal: CancellationToken?) async -> AuthRead {
        let read = readAuthSession()
        guard case .ok(var session) = read else { return read }

        // Mirror the chosen (best) session everywhere so container never lags behind ~/.grok.
        persistSession(session)

        let expiring = GrokOAuthRefresh.isExpiring(
            GrokOAuthRefresh.Entry(
                mapKey: session.mapKey,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                userId: session.userId,
                email: session.email,
                teamId: session.teamId,
                expiresAtMs: session.expiresAtMs,
                oidcIssuer: session.oidcIssuer,
                oidcClientId: session.oidcClientId,
                raw: session.rawEntry
            )
        )
        guard expiring, session.refreshToken != nil else {
            return .ok(session)
        }
        if signal?.isCancelled == true { return .ok(session) }
        if let refreshed = await forceRefresh(session: session) {
            session = refreshed
        }
        return .ok(session)
    }

    private static func forceRefresh(session: GrokAuthSession) async -> GrokAuthSession? {
        let entry = GrokOAuthRefresh.Entry(
            mapKey: session.mapKey,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            email: session.email,
            teamId: session.teamId,
            expiresAtMs: session.expiresAtMs,
            oidcIssuer: session.oidcIssuer,
            oidcClientId: session.oidcClientId,
            raw: session.rawEntry
        )
        guard let updatedRaw = await GrokOAuthRefresh.refresh(entry: entry) else { return nil }

        var full = session.fullFileJSON
        full[session.mapKey] = updatedRaw
        let newSession = GrokAuthSession(
            accessToken: (updatedRaw["key"] as? String) ?? session.accessToken,
            userId: (updatedRaw["user_id"] as? String) ?? session.userId,
            email: (updatedRaw["email"] as? String) ?? session.email,
            teamId: (updatedRaw["team_id"] as? String) ?? session.teamId,
            expiresAtMs: RateLimitFormatting.parseResetTimestamp(updatedRaw["expires_at"]),
            sourcePath: session.sourcePath,
            mapKey: session.mapKey,
            refreshToken: (updatedRaw["refresh_token"] as? String) ?? session.refreshToken,
            oidcIssuer: session.oidcIssuer,
            oidcClientId: session.oidcClientId,
            rawEntry: updatedRaw,
            fullFileJSON: full
        )
        persistSession(newSession)
        return newSession
    }

    private static func persistSession(_ session: GrokAuthSession) {
        guard let data = try? JSONSerialization.data(withJSONObject: session.fullFileJSON, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return }
        let now = Date()
        // Always write refreshed/best session to all durable locations.
        for path in [
            UsagePaths.containerGrokAuthFile,
            UsagePaths.pocketGrokAuthFile,
            UsagePaths.grokAuthFile
        ] {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: now],
                ofItemAtPath: path
            )
            _ = text // silence
        }
    }

    private static func authFileCandidates() -> [String] {
        // Order does not matter — we score by freshness. Include all mirrors.
        [
            UsagePaths.grokAuthFile,
            UsagePaths.pocketGrokAuthFile,
            UsagePaths.containerGrokAuthFile
        ]
    }

    // MARK: - Billing

    private static func fetchBilling(session: GrokAuthSession, signal: CancellationToken?) async -> ProviderRateLimits {
        do {
            let creditsData = try await getJSON(url: billingCreditsURL, session: session)
            if signal?.isCancelled == true {
                return .placeholder(provider: .grok, status: .error, error: "Rate-limit fetch aborted")
            }
            let config = resolveBillingConfig(creditsData)
            let weekly = mapWeeklyCredits(config)
            var monthly = mapMonthlyUsage(config)

            if monthly == nil {
                if let defaultData = try? await getJSON(url: billingDefaultURL, session: session) {
                    monthly = mapMonthlyUsage(resolveBillingConfig(defaultData))
                }
            }

            if weekly == nil && monthly == nil {
                return .placeholder(
                    provider: .grok,
                    status: .error,
                    error: "Grok billing returned no usage windows"
                )
            }

            let tier = (config["subscriptionTier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let authLabel = session.email?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? session.userId
                ?? "Grok account"
            let provenance = (tier?.isEmpty == false) ? "\(authLabel) (\(tier!))" : authLabel

            var meta = UsageRateLimitMetadata()
            meta.source = .oauth
            meta.authProvenance = provenance
            meta.credentialSource = session.sourcePath
            meta.lastSuccessfulSource = .oauth

            return ProviderRateLimits(
                provider: .grok,
                session: nil,
                weekly: weekly,
                fableWeekly: nil,
                monthly: monthly,
                buckets: nil,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                error: nil,
                status: .ok,
                usageMetadata: meta
            )
        } catch let err as NSError where err.domain == "GrokUsage" && (err.code == 401 || err.code == 403) {
            return .placeholder(
                provider: .grok,
                status: .error,
                error: "Grok session expired (HTTP \(err.code))"
            )
        } catch {
            return .placeholder(provider: .grok, status: .error, error: error.localizedDescription)
        }
    }

    private static func getJSON(url: URL, session: GrokAuthSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: apiTimeout)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(authHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userId = session.userId {
            request.setValue(userId, forHTTPHeaderField: "x-userid")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw NSError(
                domain: "GrokUsage",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Grok usage request failed (HTTP \(http.statusCode))"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func resolveBillingConfig(_ data: [String: Any]) -> [String: Any] {
        if let config = data["config"] as? [String: Any] {
            return config
        }
        return data
    }

    private static func mapWeeklyCredits(_ config: [String: Any]) -> RateLimitWindow? {
        let used: Double?
        if let p = config["creditUsagePercent"] as? Double { used = p }
        else if let p = config["creditUsagePercent"] as? Int { used = Double(p) }
        else if let p = config["creditUsagePercent"] as? NSNumber { used = p.doubleValue }
        else { used = nil }
        guard let usedPercent = used, usedPercent.isFinite else { return nil }

        let period = config["currentPeriod"] as? [String: Any]
        let periodEnd = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let resetsAt = RateLimitFormatting.parseResetTimestamp(periodEnd)
        return RateLimitWindow(
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: weeklyMinutes,
            resetsAt: resetsAt,
            resetDescription: RateLimitFormatting.resetDescription(fromMs: resetsAt)
        )
    }

    private static func mapMonthlyUsage(_ config: [String: Any]) -> RateLimitWindow? {
        guard let limit = parseMoneyVal(config["monthlyLimit"] as? [String: Any]),
              let used = parseMoneyVal(config["used"] as? [String: Any]),
              limit > 0 else {
            return nil
        }
        let period = config["currentPeriod"] as? [String: Any]
        let periodEnd = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let resetsAt = RateLimitFormatting.parseResetTimestamp(periodEnd)
        return RateLimitWindow(
            usedPercent: min(100, max(0, (used / limit) * 100)),
            windowMinutes: monthlyMinutes,
            resetsAt: resetsAt,
            resetDescription: RateLimitFormatting.resetDescription(fromMs: resetsAt)
        )
    }

    private static func parseMoneyVal(_ value: [String: Any]?) -> Double? {
        guard let value else { return nil }
        if let n = value["val"] as? Double { return n }
        if let n = value["val"] as? Int { return Double(n) }
        if let n = value["val"] as? NSNumber { return n.doubleValue }
        if let s = value["val"] as? String, let n = Double(s) { return n }
        return nil
    }
}
