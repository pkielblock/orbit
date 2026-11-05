import Foundation

/// One rate-limit window (session or weekly).
struct UsageWindow {
    /// 0...100, nil when the provider did not report it.
    var usedPercent: Double?
    var resetsAt: Date?
    /// Window length, used to find when the window began.
    var windowDuration: TimeInterval?
}

/// Latest known usage for one AI service.
struct ProviderUsage {
    let provider: Provider
    var session: UsageWindow?
    var weekly: UsageWindow?
    /// Short human-readable reason when data could not be fetched.
    var error: String?
    var updatedAt: Date?
    /// Missing or expired authentication requires provider-managed sign-in.
    var needsConnection = false
}

enum Provider: String, CaseIterable, Codable, Identifiable {
    case claude, codex, antigravity

    var id: Self { self }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var dashboardURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/new#settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/settings/usage?tab=overview")!
        case .antigravity: return URL(string: "https://gemini.google.com/usage")!
        }
    }

    /// The tool that owns sign-in for this provider.
    var toolName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity CLI"
        }
    }

    var helpURL: URL {
        switch self {
        case .claude: return URL(string: "https://code.claude.com/docs/en/quickstart")!
        case .codex: return URL(string: "https://developers.openai.com/codex/quickstart")!
        case .antigravity: return URL(string: "https://antigravity.google/docs/cli/install")!
        }
    }

    /// Logo file name in Resources (without extension). Drop official SVG/PNG here to replace the default.
    var logoName: String { rawValue }
}
