import Foundation

/// One rate-limit window (session or weekly).
struct UsageWindow {
    /// 0...100, nil when the provider did not report it.
    var usedPercent: Double?
    var resetsAt: Date?
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

enum Provider: CaseIterable {
    case claude, codex, antigravity

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

    /// Logo file name in Resources (without extension). Drop official SVG/PNG here to replace the default.
    var logoName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .antigravity: return "antigravity"
        }
    }
}
