//
//  GrokOAuthRefresh.swift
//  boringNotch — refresh Grok CLI OIDC access tokens so the provider does not drop.
//
//  Token endpoint verified against live auth.x.ai: POST {issuer}/oauth2/token
//

import Foundation

enum GrokOAuthRefresh {
    private static let timeout: TimeInterval = 12
    /// Refresh 5 minutes before local expires_at.
    private static let skewMs: Int64 = 5 * 60 * 1000

    struct Entry {
        var mapKey: String
        var accessToken: String
        var refreshToken: String?
        var userId: String?
        var email: String?
        var teamId: String?
        var expiresAtMs: Int64?
        var oidcIssuer: String
        var oidcClientId: String?
        var raw: [String: Any]
    }

    static func isExpiring(_ entry: Entry, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let exp = entry.expiresAtMs else { return false }
        return nowMs + skewMs >= exp
    }

    /// Refresh a single auth.json entry; returns updated raw entry dict or nil.
    static func refresh(entry: Entry) async -> [String: Any]? {
        guard let refreshToken = entry.refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else { return nil }
        guard let clientId = entry.oidcClientId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clientId.isEmpty else { return nil }

        let issuer = entry.oidcIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Live-verified path first; keep fallbacks for older CLI layouts.
        let urls = [
            "\(issuer)/oauth2/token",
            "\(issuer)/oauth/token",
            "https://auth.x.ai/oauth2/token"
        ]

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        let body = components.percentEncodedQuery?.data(using: .utf8)

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("grok-cli", forHTTPHeaderField: "User-Agent")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = json["access_token"] as? String,
                      !access.isEmpty else {
                    continue
                }

                var updated = entry.raw
                updated["key"] = access
                if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
                    updated["refresh_token"] = newRefresh
                }
                let now = Date()
                if let expiresIn = json["expires_in"] as? Double {
                    updated["expires_at"] = iso8601(now.addingTimeInterval(expiresIn))
                } else if let expiresIn = json["expires_in"] as? Int {
                    updated["expires_at"] = iso8601(now.addingTimeInterval(TimeInterval(expiresIn)))
                } else if let expiresIn = json["expires_in"] as? NSNumber {
                    updated["expires_at"] = iso8601(now.addingTimeInterval(expiresIn.doubleValue))
                } else if let expiresAt = json["expires_at"] as? String {
                    updated["expires_at"] = expiresAt
                } else {
                    updated["expires_at"] = iso8601(now.addingTimeInterval(6 * 60 * 60))
                }
                return updated
            } catch {
                continue
            }
        }
        return nil
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
