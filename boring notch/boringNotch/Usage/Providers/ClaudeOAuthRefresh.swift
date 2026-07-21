//
//  ClaudeOAuthRefresh.swift
//  boringNotch — Claude Code OAuth refresh (ported from Orca claude-accounts/oauth-refresh.ts)
//
//  Owns token rotation so Pocket does not "lose" Anthropic when access tokens expire.
//  Public Claude Code client id + token endpoint (same as installed `claude` CLI).
//

import Foundation

enum ClaudeOAuthRefresh {
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Public Claude Code OAuth client id (Orca / claude CLI).
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Refresh 5 minutes before expiry (matches CLI skew).
    private static let expiryBufferMs: Int64 = 5 * 60 * 1000
    private static let timeout: TimeInterval = 10

    /// Whether access token is missing/expired or within the refresh buffer.
    static func isAccessTokenExpiring(credentialsJSON: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let oauth = parseOauthBlob(credentialsJSON) else { return false }
        guard let expiresAt = numberMs(oauth["expiresAt"] ?? oauth["expires_at"]) else {
            // No expiry metadata → still try proactive refresh when we have a refresh token.
            return readRefreshToken(credentialsJSON) != nil
        }
        return nowMs + expiryBufferMs >= expiresAt
    }

    static func readRefreshToken(_ credentialsJSON: String) -> String? {
        guard let oauth = parseOauthBlob(credentialsJSON) else { return nil }
        let token = (oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readAccessToken(_ credentialsJSON: String) -> String? {
        guard let oauth = parseOauthBlob(credentialsJSON) else { return nil }
        let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Refresh tokens via Anthropic OAuth endpoint. Returns updated credentials JSON or nil.
    static func refresh(credentialsJSON: String) async -> String? {
        guard let refreshToken = readRefreshToken(credentialsJSON) else { return nil }

        var request = URLRequest(url: tokenURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return applyRefreshedToken(credentialsJSON: credentialsJSON, response: json)
        } catch {
            return nil
        }
    }

    /// Merge token-endpoint response into stored credentials (preserves unrelated fields).
    static func applyRefreshedToken(credentialsJSON: String, response: [String: Any], nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String? {
        guard var root = try? JSONSerialization.jsonObject(with: Data(credentialsJSON.utf8)) as? [String: Any] else {
            return nil
        }
        guard let access = response["access_token"] as? String,
              !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var oauth = (root["claudeAiOauth"] as? [String: Any])
            ?? (root["claude_ai_oauth"] as? [String: Any])
            ?? [:]
        oauth["accessToken"] = access

        if let expiresIn = response["expires_in"] as? Double, expiresIn.isFinite {
            oauth["expiresAt"] = nowMs + Int64(expiresIn * 1000)
        } else if let expiresIn = response["expires_in"] as? Int {
            oauth["expiresAt"] = nowMs + Int64(expiresIn) * 1000
        } else if let expiresIn = response["expires_in"] as? NSNumber {
            oauth["expiresAt"] = nowMs + Int64(expiresIn.doubleValue * 1000)
        }

        // Rotate refresh token when server issues a new one (single-use tokens).
        if let newRefresh = response["refresh_token"] as? String,
           !newRefresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            oauth["refreshToken"] = newRefresh
        }

        if let scope = response["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }

        root["claudeAiOauth"] = oauth
        root.removeValue(forKey: "claude_ai_oauth")

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    // MARK: - Private

    private static func parseOauthBlob(_ credentialsJSON: String) -> [String: Any]? {
        guard let data = credentialsJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (root["claudeAiOauth"] as? [String: Any])
            ?? (root["claude_ai_oauth"] as? [String: Any])
    }

    private static func numberMs(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? Double, n.isFinite { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return nil
    }
}
