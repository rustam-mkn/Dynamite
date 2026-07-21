//
//  CodexUsageFetcher.swift
//  boringNotch — Codex usage via ChatGPT backend API
//  Ported from Orca rate-limits/codex-fetcher.ts (fetchViaBackend)
//

import Foundation

enum CodexUsageFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let apiTimeout: TimeInterval = 15

    static func fetch(signal: CancellationToken? = nil) async -> ProviderRateLimits {
        if signal?.isCancelled == true {
            return .placeholder(provider: .codex, status: .error, error: "Rate-limit fetch aborted")
        }

        guard let auth = readBackendAuthHeaders() else {
            return .placeholder(
                provider: .codex,
                status: .unavailable,
                error: "Not signed in to Codex — use Sign in (needs ~/.codex/auth.json)"
            )
        }

        do {
            var request = URLRequest(url: usageURL, timeoutInterval: apiTimeout)
            for (key, value) in auth.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if signal?.isCancelled == true {
                return .placeholder(provider: .codex, status: .error, error: "Rate-limit fetch aborted")
            }
            guard let http = response as? HTTPURLResponse else {
                return .placeholder(provider: .codex, status: .error, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .placeholder(
                    provider: .codex,
                    status: .error,
                    error: "Codex session expired — use Sign in"
                )
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .placeholder(
                    provider: .codex,
                    status: .error,
                    error: "Codex usage failed (HTTP \(http.statusCode))\(body.isEmpty ? "" : ": \(body.prefix(120))")"
                )
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["plan_type"] as? String != nil else {
                return .placeholder(provider: .codex, status: .error, error: "Malformed Codex usage payload")
            }

            let rateLimit = json["rate_limit"] as? [String: Any]
            // Why: on some plans primary is the weekly bucket and secondary is null.
            let primary = mapBackendWindow(
                rateLimit?["primary_window"] as? [String: Any],
                fallbackMinutes: 300
            )
            let secondary = mapBackendWindow(
                rateLimit?["secondary_window"] as? [String: Any],
                fallbackMinutes: 10_080
            )

            // Prefer labeling by actual window length when secondary is missing.
            let session: RateLimitWindow?
            let weekly: RateLimitWindow?
            if let secondary {
                session = primary
                weekly = secondary
            } else if let primary, primary.windowMinutes >= 24 * 60 {
                session = nil
                weekly = primary
            } else {
                session = primary
                weekly = secondary
            }

            var meta = UsageRateLimitMetadata()
            meta.source = .oauth
            meta.credentialSource = auth.sourcePath
            meta.attemptedSources = [.oauth]
            meta.authProvenance = json["plan_type"] as? String

            return ProviderRateLimits(
                provider: .codex,
                session: session,
                weekly: weekly,
                fableWeekly: nil,
                monthly: nil,
                buckets: nil,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                error: nil,
                status: .ok,
                usageMetadata: meta
            )
        } catch {
            if signal?.isCancelled == true {
                return .placeholder(provider: .codex, status: .error, error: "Rate-limit fetch aborted")
            }
            return .placeholder(provider: .codex, status: .error, error: error.localizedDescription)
        }
    }

    // MARK: - Auth

    private struct AuthHeaders {
        var headers: [String: String]
        var sourcePath: String
    }

    private static func readBackendAuthHeaders() -> AuthHeaders? {
        let candidates = [
            UsagePaths.codexAuthFile,
            UsagePaths.pocketCodexAuthFile,
            UsagePaths.containerCodexAuthFile
        ]
        // Prefer newest file — never let a stale container shadow ~/.codex/auth.json.
        guard let (data, path) = UsagePaths.newestExistingData(among: candidates),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Mirror freshest session into durable paths (won't clobber newer destinations).
        if let text = String(data: data, encoding: .utf8) {
            let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
            _ = UsagePaths.persistAuthJSONIfNewer(
                text,
                containerPath: UsagePaths.containerCodexAuthFile,
                homePath: UsagePaths.pocketCodexAuthFile,
                sourceMTime: mtime
            )
        }

        // Standard ChatGPT/Codex OAuth shape
        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = (tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String),
           !accessToken.isEmpty {
            return makeHeaders(accessToken: accessToken, accountId: tokens["account_id"] as? String ?? tokens["accountId"] as? String, source: path)
        }

        // Alternate top-level keys some wrappers use
        if let accessToken = (json["access_token"] as? String) ?? (json["accessToken"] as? String),
           !accessToken.isEmpty {
            return makeHeaders(accessToken: accessToken, accountId: json["account_id"] as? String, source: path)
        }

        return nil
    }

    private static func makeHeaders(accessToken: String, accountId: String?, source: String) -> AuthHeaders {
        var headers: [String: String] = [
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": "codex-cli",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountId, !accountId.isEmpty {
            headers["ChatGPT-Account-Id"] = accountId
        }
        return AuthHeaders(headers: headers, sourcePath: source)
    }

    // MARK: - Mapping

    private static func mapBackendWindow(_ raw: [String: Any]?, fallbackMinutes: Int) -> RateLimitWindow? {
        guard let raw else { return nil }
        let used: Double?
        if let u = raw["used_percent"] as? Double { used = u }
        else if let u = raw["used_percent"] as? Int { used = Double(u) }
        else if let u = raw["used_percent"] as? NSNumber { used = u.doubleValue }
        else { used = nil }
        guard let usedPercent = used, usedPercent.isFinite else { return nil }

        let windowMinutes: Int
        if let seconds = raw["limit_window_seconds"] as? Double, seconds > 0 {
            windowMinutes = Int(ceil(seconds / 60.0))
        } else if let seconds = raw["limit_window_seconds"] as? Int, seconds > 0 {
            windowMinutes = Int(ceil(Double(seconds) / 60.0))
        } else if let seconds = raw["limit_window_seconds"] as? NSNumber, seconds.doubleValue > 0 {
            windowMinutes = Int(ceil(seconds.doubleValue / 60.0))
        } else {
            windowMinutes = fallbackMinutes
        }

        // Why: Codex returns reset_at as Unix seconds (sometimes far-future epoch).
        let resetsAt: Int64?
        if let r = raw["reset_at"] as? Double, r > 0 {
            resetsAt = r > 10_000_000_000 ? Int64(r) : Int64(r * 1000)
        } else if let r = raw["reset_at"] as? Int, r > 0 {
            let v = Int64(r)
            resetsAt = v > 10_000_000_000 ? v : v * 1000
        } else if let r = raw["reset_at"] as? Int64, r > 0 {
            resetsAt = r > 10_000_000_000 ? r : r * 1000
        } else if let r = raw["reset_at"] as? NSNumber, r.doubleValue > 0 {
            let d = r.doubleValue
            resetsAt = d > 10_000_000_000 ? Int64(d) : Int64(d * 1000)
        } else {
            resetsAt = nil
        }

        return RateLimitWindow(
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: RateLimitFormatting.resetDescription(fromMs: resetsAt)
        )
    }
}
