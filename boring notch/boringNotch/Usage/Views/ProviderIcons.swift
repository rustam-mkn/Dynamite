//
//  ProviderIcons.swift
//  boringNotch — load provider/agent images extracted from Orca
//
//  Sources (copied into Usage/Icons + Assets.xcassets):
//    orca/src/renderer/.../icons.tsx  → Claude / OpenAI SVG
//    orca/src/shared/agent-icons/*.png
//    orca/resources/{claude.webp,opencode.webp,minimax-icon.svg,...}
//

import AppKit
import SwiftUI

// MARK: - Provider (usage columns)

struct ProviderIconView: View {
    let provider: UsageProviderID
    var size: CGFloat = 14

    var body: some View {
        OrcaIconImage(names: providerFileNames, size: size, fallbackSystem: fallbackSystem, tint: tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var providerFileNames: [String] {
        switch provider {
        case .claude: return ["provider_claude", "ProviderClaude"]
        case .codex: return ["provider_codex", "ProviderCodex"]
        case .grok: return ["provider_grok", "ProviderGrok", "agent_grok", "Agent_grok"]
        case .gemini: return ["provider_gemini", "ProviderGemini", "agent_gemini", "Agent_gemini"]
        case .antigravity: return ["agent_antigravity", "Agent_antigravity", "provider_gemini"]
        case .kimi: return ["provider_kimi", "ProviderKimi", "agent_kimi", "Agent_kimi"]
        case .opencodeGo: return ["provider_opencode", "ProviderOpenCode", "agent_opencode", "Agent_opencode"]
        case .minimax: return ["provider_minimax", "ProviderMiniMax"]
        }
    }

    private var fallbackSystem: String {
        switch provider {
        case .claude: return "sparkle"
        case .codex: return "circle.hexagongrid.fill"
        case .grok: return "x.circle"
        case .gemini, .antigravity: return "sparkles"
        case .kimi: return "moon.stars"
        case .opencodeGo: return "chevron.left.forwardslash.chevron.right"
        case .minimax: return "waveform"
        }
    }

    private var tint: Color? {
        // Only tint SF Symbol fallback for Claude brand color
        switch provider {
        case .claude: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        default: return nil
        }
    }
}

// MARK: - Agent catalog

struct AgentCatalogIcon: View {
    let agentID: TuiAgentID
    var size: CGFloat = 16

    var body: some View {
        OrcaIconImage(names: fileNames, size: size, fallbackSystem: "terminal", tint: nil)
            .frame(width: size, height: size)
            .overlay {
                if !OrcaIconLoader.hasAny(fileNames) {
                    // Letter badge when no Orca art
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.secondary.opacity(0.22))
                    Text(String(agentID.rawValue.prefix(1)).uppercased())
                        .font(.notch(size: size * 0.48, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var fileNames: [String] {
        // Prefer dedicated agent_*, then provider art from Orca
        var names: [String] = []
        if let agent = Self.agentAssetStem(for: agentID) {
            names.append(contentsOf: ["agent_\(agent)", "Agent_\(agent)"])
        }
        switch agentID {
        case .claude, .claudeAgentTeams:
            names.append(contentsOf: ["provider_claude", "ProviderClaude"])
        case .codex:
            names.append(contentsOf: ["provider_codex", "ProviderCodex"])
        case .grok:
            names.append(contentsOf: ["provider_grok", "ProviderGrok"])
        case .gemini:
            names.append(contentsOf: ["provider_gemini", "ProviderGemini"])
        case .kimi:
            names.append(contentsOf: ["provider_kimi", "ProviderKimi"])
        case .opencode, .mimoCode:
            names.append(contentsOf: ["provider_opencode", "ProviderOpenCode"])
        case .antigravity:
            names.append(contentsOf: ["agent_antigravity", "provider_gemini"])
        default:
            break
        }
        return names
    }

    static func agentAssetStem(for id: TuiAgentID) -> String? {
        switch id {
        case .claude, .claudeAgentTeams: return nil // use ProviderClaude
        case .codex: return nil
        case .openclaude: return "openclaude"
        case .opencode: return "opencode"
        case .mimoCode: return "mimo_code"
        case .ante: return "ante"
        case .gemini: return "gemini"
        case .antigravity: return "antigravity"
        case .goose: return "goose"
        case .amp: return "amp"
        case .kilo: return "kilo"
        case .kiro: return "kiro"
        case .crush: return "crush"
        case .aug: return "aug"
        case .autohand: return "autohand"
        case .cline: return "cline"
        case .codebuff: return "codebuff"
        case .commandCode: return "command_code"
        case .continueAgent: return "continue"
        case .cursor: return "cursor"
        case .droid: return "droid"
        case .kimi: return "kimi"
        case .mistralVibe: return "mistral_vibe"
        case .qwenCode: return "qwen_code"
        case .rovo: return "rovo"
        case .hermes: return "hermes"
        case .devin: return "devin"
        case .openclaw: return "openclaw"
        case .copilot: return "copilot"
        case .grok: return "grok"
        case .pi, .omp, .aider: return nil
        }
    }

    static func providerMapping(for id: TuiAgentID) -> UsageProviderID? {
        switch id {
        case .claude, .claudeAgentTeams: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .gemini: return .gemini
        case .kimi: return .kimi
        case .opencode, .mimoCode: return .opencodeGo
        case .antigravity: return .antigravity
        default: return nil
        }
    }
}

// MARK: - Loader (bundle file → asset catalog → SF Symbol)

enum OrcaIconLoader {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(names: [String]) -> NSImage? {
        for name in names {
            if let img = load(name) { return img }
        }
        return nil
    }

    static func hasAny(_ names: [String]) -> Bool {
        image(names: names) != nil
    }

    private static func load(_ name: String) -> NSImage? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var found: NSImage?

        // 1) Usage/Icons/*.png (FileSystemSynchronized → app Resources)
        if let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Usage/Icons") {
            found = NSImage(contentsOf: url)
        }

        // 2) Asset catalog
        if found == nil {
            found = NSImage(named: name)
        }

        // 3) Search in bundle for nested path
        if found == nil, let resourcePath = Bundle.main.resourcePath {
            let candidates = [
                "\(resourcePath)/\(name).png",
                "\(resourcePath)/Icons/\(name).png",
                "\(resourcePath)/Usage/Icons/\(name).png"
            ]
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                if let img = NSImage(contentsOfFile: path) {
                    found = img
                    break
                }
            }
        }

        if let found {
            lock.lock()
            cache[name] = found
            lock.unlock()
        }
        return found
    }
}

struct OrcaIconImage: View {
    let names: [String]
    var size: CGFloat = 14
    var fallbackSystem: String = "questionmark"
    var tint: Color? = nil
    /// Orca rounds square provider/agent marks (~20–25% corner radius of size).
    var roundCorners: Bool = true

    var body: some View {
        Group {
            if let nsImage = OrcaIconLoader.image(names: names) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .modifier(SquareRoundedClip(enabled: roundCorners && isSquare(nsImage), size: size))
            } else if let tint {
                Image(systemName: fallbackSystem)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
            } else {
                Image(systemName: fallbackSystem)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private func isSquare(_ image: NSImage) -> Bool {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return true }
        let ratio = s.width / s.height
        return abs(ratio - 1) < 0.12
    }
}

/// Clip square artwork with rounded corners (Orca tab/status icons).
private struct SquareRoundedClip: ViewModifier {
    let enabled: Bool
    let size: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.22), style: .continuous))
        } else {
            content
        }
    }
}
