//
//  ProviderAuthService.swift
//  boringNotch — provider sign-in without Gatekeeper .command dialogs.
//
//  Flow:
//    1. Open the provider login page in the default browser immediately.
//    2. Start the CLI auth bridge in a *hidden* Terminal window (no .command
//       files, no activate) so OAuth tokens land on disk for usage fetch.
//
//  Claude Code stores OAuth in Keychain. The app never calls Security.framework
//  (that triggers the "TheBoringNotch wants Claude Code-credentials" dialog).
//  The hidden Terminal bridge exports the keychain blob to:
//    ~/.claude/.credentials.json
//    ~/Library/Application Support/boringNotch/UsageAuth/claude.credentials.json
//

import AppKit
import Foundation

enum ProviderAuthService {
    /// Real user home (not the app-sandbox container).
    static var realHomeDirectory: String { UsagePaths.realHome }

    static var pocketClaudeCredentialsPath: String { UsagePaths.pocketClaudeCredentialsFile }

    static var claudeLegacyCredentialsPath: String { UsagePaths.claudeCredentialsFile }

    /// Human-readable login command for a provider.
    static func loginCommand(for provider: UsageProviderID) -> String {
        switch provider {
        case .claude:
            return "claude auth login (+ export creds for Pocket)"
        case .codex:
            return "codex login"
        case .grok:
            return "grok login"
        case .gemini, .antigravity:
            return "gemini"
        case .kimi:
            return "kimi"
        case .opencodeGo:
            return "opencode"
        case .minimax:
            return "echo 'Paste MiniMax session cookie in Settings (Orca-style)'"
        }
    }

    /// Sign in: browser first, CLI bridge hidden (no Gatekeeper .command dialog).
    @discardableResult
    static func beginSignIn(for provider: UsageProviderID) -> Bool {
        // Already have durable Claude session → export only (do not force re-login / token rotation).
        if provider == .claude, ClaudeUsageFetcher.hasStoredCredentials() {
            return syncClaudeCredentialsOnly()
        }

        // 1) Immediate browser — what the user sees.
        openBrowserLogin(for: provider)

        // 2) Hidden CLI bridge so OAuth/session files are written after browser auth.
        //    Never opens a .command document (Gatekeeper "damaged app" dialog).
        DispatchQueue.global(qos: .userInitiated).async {
            _ = launchAuthBridge(
                script: shellScript(for: provider, mode: .loginAndSync),
                title: "\(provider.displayName) login",
                hideTerminal: true
            )
        }
        return true
    }

    /// Already signed into Claude CLI — only export Keychain → file for Pocket (no re-login).
    @discardableResult
    static func syncClaudeCredentialsOnly() -> Bool {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = launchAuthBridge(
                script: shellScript(for: .claude, mode: .syncOnly),
                title: "Claude sync credentials",
                hideTerminal: true
            )
        }
        return true
    }

    /// Open provider docs / account page when CLI is not available.
    static func openAccountPage(for provider: UsageProviderID) {
        openBrowserLogin(for: provider)
    }

    /// Browser destinations for each provider (login / account).
    static func openBrowserLogin(for provider: UsageProviderID) {
        let urlString: String
        switch provider {
        case .claude:
            // Claude.ai login (CLI also opens its own OAuth URL with PKCE).
            urlString = "https://claude.ai/login"
        case .codex:
            urlString = "https://chatgpt.com/auth/login"
        case .grok:
            urlString = "https://accounts.x.ai/sign-in"
        case .gemini, .antigravity:
            urlString = "https://aistudio.google.com"
        case .kimi:
            urlString = "https://www.kimi.com"
        case .opencodeGo:
            urlString = "https://opencode.ai"
        case .minimax:
            urlString = "https://platform.minimax.io/console/usage"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scripts

    private enum AuthMode {
        case loginAndSync
        case syncOnly
    }

    private static func shellScript(for provider: UsageProviderID, mode: AuthMode) -> String {
        let pathExtras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(realHomeDirectory)/.local/bin",
            "\(realHomeDirectory)/.grok/bin",
            "\(realHomeDirectory)/.volta/bin",
            "\(realHomeDirectory)/.bun/bin",
            "\(realHomeDirectory)/Library/pnpm"
        ]
        let exportPath = "export PATH=\"\(pathExtras.joined(separator: ":")):$PATH\""
        let home = realHomeDirectory

        switch provider {
        case .claude:
            return claudeScript(exportPath: exportPath, home: home, mode: mode)
        case .codex:
            return fileAuthLoginScript(
                exportPath: exportPath,
                home: home,
                command: "codex login",
                sourceFile: "\(home)/.codex/auth.json",
                pocketFile: "\(home)/Library/Application Support/boringNotch/UsageAuth/codex.auth.json",
                containerFile: UsagePaths.containerCodexAuthFile,
                label: "Codex"
            )
        case .grok:
            return fileAuthLoginScript(
                exportPath: exportPath,
                home: home,
                command: "grok login",
                sourceFile: "\(home)/.grok/auth.json",
                pocketFile: "\(home)/Library/Application Support/boringNotch/UsageAuth/grok.auth.json",
                containerFile: UsagePaths.containerGrokAuthFile,
                label: "Grok"
            )
        default:
            return genericLoginScript(
                exportPath: exportPath,
                command: loginCommand(for: provider),
                successHint: "Done."
            )
        }
    }

    private static func claudeScript(exportPath: String, home: String, mode: AuthMode) -> String {
        // Export runs outside the app sandbox so `security` can read Claude Code keychain
        // items without TheBoringNotch ACL prompt. Writes files Pocket is allowed to read.
        let pocketDir = "\(home)/Library/Application Support/boringNotch/UsageAuth"
        let pocketFile = "\(pocketDir)/claude.credentials.json"
        let legacyFile = "\(home)/.claude/.credentials.json"
        // Sandbox container path (always readable by the app after export).
        let containerFile = UsagePaths.containerClaudeCredentialsFile
        let containerDir = UsagePaths.containerUsageAuthDir

        let loginBlock: String
        switch mode {
        case .loginAndSync:
            loginBlock = """
            if claude auth status 2>/dev/null | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
              echo "Claude already signed in — exporting credentials for Pocket…"
            else
              echo "→ claude auth login"
              # CLI opens the correct OAuth URL in the browser (PKCE).
              claude auth login
              login_status=$?
              if [ $login_status -ne 0 ]; then
                echo "Login exited with code $login_status"
              fi
            fi
            """
        case .syncOnly:
            loginBlock = """
            echo "Exporting existing Claude Keychain session for Pocket (no re-login)…"
            if ! claude auth status 2>/dev/null | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
              echo "Not signed in. Run Sign in first."
              exit 1
            fi
            """
        }

        return """
        \(exportPath)
        export HOME="\(home)"
        echo "Pocket — Claude auth bridge"
        echo ""
        \(loginBlock)
        echo ""
        echo "Exporting credentials to files Pocket can read…"
        mkdir -p "\(home)/.claude" "\(pocketDir)" "\(containerDir)"

        export_ok=0
        # Claude Code stores under account "user" and/or $USER; try both + scoped service names.
        CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        if command -v shasum >/dev/null 2>&1; then
          SUFFIX=$(printf '%s' "$CONFIG_DIR" | shasum -a 256 | cut -c1-8)
        else
          SUFFIX=$(printf '%s' "$CONFIG_DIR" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-8)
        fi
        SERVICES=("Claude Code-credentials" "Claude Code-credentials-$SUFFIX")
        ACCOUNTS=("user" "$USER" "$(whoami)")

        for svc in "${SERVICES[@]}"; do
          for acct in "${ACCOUNTS[@]}"; do
            raw=$(security find-generic-password -s "$svc" -a "$acct" -w 2>/dev/null) || continue
            if [ -n "$raw" ]; then
              printf '%s' "$raw" > "\(legacyFile)"
              printf '%s' "$raw" > "\(pocketFile)"
              printf '%s' "$raw" > "\(containerFile)"
              chmod 600 "\(legacyFile)" "\(pocketFile)" "\(containerFile)" 2>/dev/null || true
              echo "✓ Exported from Keychain service '$svc' (account $acct)"
              echo "  → \(legacyFile)"
              echo "  → \(pocketFile)"
              echo "  → \(containerFile)"
              export_ok=1
              break 2
            fi
          done
        done

        if [ $export_ok -eq 0 ]; then
          echo "✗ Could not read Claude Code credentials from Keychain."
          echo "  Try: claude auth login, then run this again."
          exit 2
        fi

        echo ""
        echo "Done. Return to Pocket — usage should refresh within a few seconds."
        """
    }

    private static func genericLoginScript(exportPath: String, command: String, successHint: String) -> String {
        """
        echo "Pocket — signing in…"
        echo "→ \(command)"
        echo ""
        \(exportPath)
        \(command)
        status=$?
        echo ""
        if [ $status -eq 0 ]; then
          echo "Done. \(successHint)"
          echo "Return to Pocket; usage refreshes automatically."
        else
          echo "Login exited with code $status."
        fi
        """
    }

    /// Codex / Grok: login then copy auth.json into Pocket UsageAuth for reliable sandbox reads.
    private static func fileAuthLoginScript(
        exportPath: String,
        home: String,
        command: String,
        sourceFile: String,
        pocketFile: String,
        containerFile: String,
        label: String
    ) -> String {
        let pocketDir = "\(home)/Library/Application Support/boringNotch/UsageAuth"
        let containerDir = (containerFile as NSString).deletingLastPathComponent
        return """
        \(exportPath)
        export HOME="\(home)"
        echo "Pocket — \(label) auth"
        echo ""
        if [ -f "\(sourceFile)" ]; then
          echo "Existing \(label) session found — will refresh login if needed."
        fi
        echo "→ \(command)"
        \(command)
        status=$?
        echo ""
        mkdir -p "\(pocketDir)" "\(containerDir)"
        if [ -f "\(sourceFile)" ]; then
          cp "\(sourceFile)" "\(pocketFile)"
          cp "\(sourceFile)" "\(containerFile)"
          chmod 600 "\(pocketFile)" "\(containerFile)" 2>/dev/null || true
          echo "✓ \(label) auth available:"
          echo "  → \(sourceFile)"
          echo "  → \(pocketFile)"
          echo "  → \(containerFile)"
          echo ""
          echo "Done. Return to Pocket — usage should refresh within a few seconds."
          exit 0
        fi
        if [ $status -ne 0 ]; then
          echo "Login exited with code $status and no auth file was written."
        else
          echo "Login finished but \(sourceFile) was not found."
        fi
        exit 1
        """
    }

    // MARK: - Launch (no .command / no Gatekeeper dialog)

    /// Write a private `.sh` (never opened as a document) and run it via Terminal AppleScript.
    /// When `hideTerminal` is true the window is miniaturized and Terminal is not activated,
    /// so the user mainly sees the browser OAuth flow.
    @discardableResult
    private static func launchAuthBridge(script: String, title: String, hideTerminal: Bool) -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boringNotch-provider-auth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let safe = title
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        // Use .sh — never .command (LaunchServices treats .command as an app and Gatekeeper blocks it).
        let scriptURL = dir.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8)).sh")
        let body = "#!/bin/zsh\nset +e\n\(script)\n"
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            return runViaAppleScript(inlineCommand: script, hideTerminal: hideTerminal)
        }

        // Strip quarantine if present so zsh can execute; we never `open` this file as a document.
        stripQuarantine(at: scriptURL.path)

        let path = scriptURL.path
        let shellCommand = "/bin/zsh " + shellQuote(path)
        return runViaAppleScript(inlineCommand: shellCommand, hideTerminal: hideTerminal)
    }

    private static func runViaAppleScript(inlineCommand: String, hideTerminal: Bool) -> Bool {
        let escaped = inlineCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let hideBlock: String
        if hideTerminal {
            hideBlock = """
              try
                set miniaturized of front window to true
              end try
            """
        } else {
            hideBlock = "activate"
        }

        let source = """
        tell application "Terminal"
          do script "\(escaped)"
          \(hideBlock)
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: source) {
            appleScript.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func stripQuarantine(at path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-d", "com.apple.quarantine", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
