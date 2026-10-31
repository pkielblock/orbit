import AppKit
import SwiftUI

/// Provider tools own sign-in and credential storage; Orbit never asks users to paste tokens.
struct ProviderConnections: View {
    @ObservedObject var model: GalaxyModel
    let refresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Provider?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your providers").font(.system(size: 18, weight: .medium))
            Text("Orbit uses accounts signed in through your provider tools. Complete sign-in, then check connections.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(Array(Provider.allCases.enumerated()), id: \.offset) { _, provider in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.name).font(.system(size: 15, weight: .medium))
                        Spacer()
                        Text(status(provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(instructions(provider)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if let command = command(provider) {
                        Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Button(copied == provider ? String(localized: "Copied, paste it in Terminal") : String(localized: "Copy command and open Terminal")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = provider
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Galaxy.accentText)
                    }
                    Link("Installation and sign-in help", destination: helpURL(provider)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Button(model.refreshing ? String(localized: "Checking…") : String(localized: "Check connections"), action: refresh).disabled(model.refreshing)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: {
                    Text("Done").fontWeight(.medium).padding(.horizontal, 16).frame(height: 28)
                        .background(Galaxy.accent, in: Capsule())
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 392)
        .background(Color(white: 0.04)) // T3 Black surface #0a0a0a
        .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
    }

    private func status(_ provider: Provider) -> String {
        guard let usage = model.usage[provider] else { return String(localized: "Not checked") }
        if usage.needsConnection { return String(localized: "Sign-in needed") }
        return usage.error == nil ? String(localized: "Connected") : String(localized: "Check connection")
    }

    private func instructions(_ provider: Provider) -> String {
        switch provider {
        case .claude: return String(localized: "Install Claude Code if needed. Run this command and sign in with your Claude subscription. Allow Keychain access when prompted.")
        case .codex: return String(localized: "Install Codex CLI if needed. Run this command and choose Sign in with ChatGPT. An API key does not provide subscription quotas.")
        case .antigravity: return String(localized: "Install Antigravity CLI if needed. Run agy and complete interactive sign-in. Orbit then reads your account quotas through /usage.")
        }
    }

    private func command(_ provider: Provider) -> String? {
        let tool: String
        let arguments: String
        switch provider {
        case .claude: tool = "claude"; arguments = "auth login"
        case .codex: tool = "codex"; arguments = "login"
        case .antigravity: tool = "agy"; arguments = ""
        }
        // Quote discovered paths so spaces and shell metacharacters remain literal.
        let executable = ProviderTools.executable(tool).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? tool
        return arguments.isEmpty ? executable : "\(executable) \(arguments)"
    }

    private func helpURL(_ provider: Provider) -> URL {
        switch provider {
        case .claude: return URL(string: "https://code.claude.com/docs/en/quickstart")!
        case .codex: return URL(string: "https://developers.openai.com/codex/quickstart")!
        case .antigravity: return URL(string: "https://antigravity.google/docs/cli/install")!
        }
    }
}
