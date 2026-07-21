//
//  UsagePaths.swift
//  boringNotch — real-user paths for auth files (sandbox-safe)
//
//  App Sandbox makes NSHomeDirectory() point at the container, not the user's
//  real home. CLI tools write to ~/.codex, ~/.grok, ~/.claude on the real home.
//  Always resolve via getpwuid + home-relative sandbox exceptions.
//

import Foundation

enum UsagePaths {
    /// Real user home directory (e.g. /Users/name), never the sandbox container.
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        // Fallback: HOME may still be container under sandbox — try unsetting
        if let home = ProcessInfo.processInfo.environment["HOME"], home.contains("/Users/") {
            return home
        }
        return NSHomeDirectory()
    }

    static func underHome(_ components: String...) -> String {
        components.reduce(realHome) { ($0 as NSString).appendingPathComponent($1) }
    }

    // MARK: Claude
    static var claudeConfigDir: String {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return underHome(".claude")
    }

    static var claudeCredentialsFile: String {
        (claudeConfigDir as NSString).appendingPathComponent(".credentials.json")
    }

    static var pocketClaudeCredentialsFile: String {
        underHome("Library", "Application Support", "boringNotch", "UsageAuth", "claude.credentials.json")
    }

    /// Always-writable path inside the app sandbox container (durable across restarts).
    static var containerUsageAuthDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("boringNotch/UsageAuth", isDirectory: true).path
    }

    static var containerClaudeCredentialsFile: String {
        (containerUsageAuthDir as NSString).appendingPathComponent("claude.credentials.json")
    }

    static var containerCodexAuthFile: String {
        (containerUsageAuthDir as NSString).appendingPathComponent("codex.auth.json")
    }

    static var containerGrokAuthFile: String {
        (containerUsageAuthDir as NSString).appendingPathComponent("grok.auth.json")
    }

    /// Ensure UsageAuth directories exist (container always; real-home best-effort).
    static func ensureUsageAuthDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: containerUsageAuthDir, withIntermediateDirectories: true)
        let homeDir = underHome("Library", "Application Support", "boringNotch", "UsageAuth")
        try? fm.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
    }

    /// Persist auth JSON to container (required) + real-home pocket path (best-effort).
    @discardableResult
    static func persistAuthJSON(_ json: String, containerPath: String, homePath: String?) -> Bool {
        ensureUsageAuthDirectories()
        var wrote = false
        let data = Data(json.utf8)
        do {
            try data.write(to: URL(fileURLWithPath: containerPath), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: containerPath)
            wrote = true
        } catch {
            // Container write failure is unexpected under sandbox.
        }
        if let homePath {
            do {
                let dir = (homePath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: homePath), options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: homePath)
            } catch {
                // Home path may be read-only under sandbox; container copy is enough.
            }
        }
        return wrote
    }

    // MARK: Codex
    static var codexHome: String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return underHome(".codex")
    }

    static var codexAuthFile: String {
        (codexHome as NSString).appendingPathComponent("auth.json")
    }

    static var pocketCodexAuthFile: String {
        underHome("Library", "Application Support", "boringNotch", "UsageAuth", "codex.auth.json")
    }

    // MARK: Grok
    static var grokHome: String {
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return underHome(".grok")
    }

    static var grokAuthFile: String {
        (grokHome as NSString).appendingPathComponent("auth.json")
    }

    static var pocketGrokAuthFile: String {
        underHome("Library", "Application Support", "boringNotch", "UsageAuth", "grok.auth.json")
    }

    /// Read first existing file among candidates.
    static func firstExistingData(among paths: [String]) -> (Data, String)? {
        let fm = FileManager.default
        for path in paths {
            if fm.fileExists(atPath: path),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               !data.isEmpty {
                return (data, path)
            }
        }
        return nil
    }

    /// Prefer the **newest** non-empty file (by mtime). Prevents a stale container
    /// mirror from shadowing a fresher `~/.grok/auth.json` / CLI session.
    static func newestExistingData(among paths: [String]) -> (Data, String)? {
        let fm = FileManager.default
        var best: (Data, String, Date)?
        var seen = Set<String>()
        for path in paths {
            guard seen.insert(path).inserted else { continue }
            guard fm.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  !data.isEmpty else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime >= best!.2 {
                best = (data, path, mtime)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    /// Write auth JSON only when destination is missing or older than `sourceMTime`.
    @discardableResult
    static func persistAuthJSONIfNewer(
        _ json: String,
        containerPath: String,
        homePath: String?,
        sourceMTime: Date?
    ) -> Bool {
        ensureUsageAuthDirectories()
        let data = Data(json.utf8)
        let fm = FileManager.default
        let sourceDate = sourceMTime ?? Date()

        func writeIfNewer(to path: String) -> Bool {
            if fm.fileExists(atPath: path),
               let destDate = try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date,
               destDate > sourceDate {
                // Destination is newer — do not clobber a fresher CLI session.
                return false
            }
            do {
                let dir = (path as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                // Preserve "freshness" relative to source when possible.
                try? fm.setAttributes([.modificationDate: sourceDate], ofItemAtPath: path)
                return true
            } catch {
                return false
            }
        }

        var wrote = writeIfNewer(to: containerPath)
        if let homePath {
            wrote = writeIfNewer(to: homePath) || wrote
        }
        return wrote
    }
}
