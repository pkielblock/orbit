import Foundation

/// One sign-in for a provider. Holds no secrets: credentials stay with the provider tools.
struct Account: Codable, Identifiable, Hashable {
    let id: UUID
    let provider: Provider
    var name: String
    /// The provider's config folder for this account; nil is the provider's default account.
    let folder: String?

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// A fixed id, so the default account keeps its identity through corrupt or missing stored data.
    static func defaultAccount(_ provider: Provider, name: String? = nil) -> Account {
        let suffix: Int
        switch provider {
        case .claude: suffix = 1
        case .codex: suffix = 2
        case .antigravity: suffix = 3
        }
        return Account(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(suffix)")!, provider: provider,
                       name: name ?? String(localized: "Default"), folder: nil)
    }

    static func defaultFolder(_ provider: Provider, home: String = Account.home) -> String {
        switch provider {
        case .claude: return "\(home)/.claude"
        case .codex: return "\(home)/.codex"
        case .antigravity: return home
        }
    }

    func resolvedFolder(home: String = Account.home) -> String { folder ?? Self.defaultFolder(provider, home: home) }

    /// Where this account's tool writes token logs. Antigravity's have no readable counts.
    func logRoots(home: String = Account.home) -> [String] {
        let root = resolvedFolder(home: home)
        switch provider {
        case .claude: return ["\(root)/projects"]
        case .codex: return ["\(root)/sessions", "\(root)/archived_sessions"]
        case .antigravity: return []
        }
    }

    /// The Terminal command for signing in. The default account's has no environment prefix.
    func signInCommand(executable: (String) -> String? = { ProviderTools.executable($0) }) -> String {
        let tool: String
        let arguments: String
        let variable: String
        switch provider {
        case .claude: tool = "claude"; arguments = " auth login"; variable = "CLAUDE_CONFIG_DIR"
        case .codex: tool = "codex"; arguments = " login"; variable = "CODEX_HOME"
        case .antigravity: tool = "agy"; arguments = ""; variable = "HOME"
        }
        let prefix = folder.map { "\(variable)=\(ProviderTools.quoted($0)) " } ?? ""
        return prefix + (executable(tool).map(ProviderTools.quoted) ?? tool) + arguments
    }

    func makeSource() -> UsageSource {
        switch provider {
        case .claude:
            let folder = folder
            return ClaudeSource(tokenReader: { try ClaudeCredentials.accessToken(folder: folder) })
        case .codex: return CodexSource(folder: folder)
        case .antigravity: return AntigravitySource(folder: folder)
        }
    }
}

/// Account list in UserDefaults as JSON. Stored data is never trusted: invalid entries are dropped, defaults always stay.
enum AccountStore {
    private static let key = "accounts"

    static func load(defaults: UserDefaults = .standard, home: String = Account.home) -> [Account] {
        decode(defaults.data(forKey: key), home: home)
    }

    static func save(_ accounts: [Account], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: key)
    }

    static func decode(_ data: Data?, home: String = Account.home) -> [Account] {
        // One bad entry must not lose the others.
        struct Lossy: Decodable {
            let account: Account?
            init(from decoder: Decoder) { account = try? Account(from: decoder) }
        }
        let stored = data.flatMap { try? JSONDecoder().decode([Lossy].self, from: $0) }?.compactMap(\.account) ?? []
        return sanitize(stored, home: home)
    }

    /// Exactly one default account per provider, first in its list, then the valid added accounts in stored order.
    static func sanitize(_ stored: [Account], home: String = Account.home) -> [Account] {
        // Ids key usage and sources across providers, so they must be unique across providers too. Default ids are reserved.
        var usedIDs = Set(Provider.allCases.map { Account.defaultAccount($0).id })
        return Provider.allCases.flatMap { provider -> [Account] in
            let mine = stored.filter { $0.provider == provider }
            let name = mine.first { $0.folder == nil }.map { trimmed($0.name) }.flatMap { $0.isEmpty ? nil : $0 }
            var kept = [Account.defaultAccount(provider, name: name)]
            for account in mine {
                guard let folder = account.folder, folder.hasPrefix("/"), !folder.contains("\0"),
                      !trimmed(account.name).isEmpty,
                      !folderUsed(folder, provider: provider, in: kept, home: home),
                      usedIDs.insert(account.id).inserted else { continue }
                kept.append(account)
            }
            return kept
        }
    }

    static func trimmed(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func nameUsed(_ name: String, provider: Provider, in accounts: [Account], except id: UUID? = nil) -> Bool {
        let wanted = trimmed(name).lowercased()
        return accounts.contains { $0.provider == provider && $0.id != id && $0.name.lowercased() == wanted }
    }

    /// Compares real paths, so a symlink or an oddly cased path can't add the same folder twice.
    static func folderUsed(_ folder: String, provider: Provider, in accounts: [Account], home: String = Account.home) -> Bool {
        func real(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        }
        let wanted = real(folder)
        return real(Account.defaultFolder(provider, home: home)) == wanted
            || accounts.contains { $0.provider == provider && real($0.resolvedFolder(home: home)) == wanted }
    }

    /// A UUID, not the typed name: no traversal or collisions, and renames never touch the path.
    static func newFolder(_ provider: Provider, id: UUID, home: String = Account.home) -> String {
        "\(home)/Library/Application Support/Orbit/\(provider.rawValue)/\(id.uuidString)"
    }

    /// Private to the user, since provider tools keep credentials here.
    static func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func logRoots(_ accounts: [Account], home: String = Account.home) -> [Provider: [String]] {
        var roots: [Provider: [String]] = [.claude: [], .codex: []]
        for account in accounts where account.provider != .antigravity {
            roots[account.provider, default: []] += account.logRoots(home: home)
        }
        return roots
    }
}

/// Runs quota refreshes: one long-lived source per account, since ClaudeSource holds rate-limit backoff and last-good state.
@MainActor
final class AccountRefresher {
    private let model: GalaxyModel
    private let makeSource: (Account) -> UsageSource
    private(set) var sources: [UUID: UsageSource] = [:]
    private var refreshAgain = false
    /// Runs after each result lands, since a result can change the panel's height while the pass goes on.
    var resultApplied: () -> Void = {}

    init(model: GalaxyModel, makeSource: @escaping (Account) -> UsageSource = { $0.makeSource() }) {
        self.model = model
        self.makeSource = makeSource
        sync()
    }

    /// Keeps existing instances; a removed account's source goes, a new account gets one.
    func sync() {
        let ids = Set(model.accounts.map(\.id))
        sources = sources.filter { ids.contains($0.key) }
        for account in model.accounts where sources[account.id] == nil { sources[account.id] = makeSource(account) }
    }

    /// `finished` runs after each pass. A request during a pass runs one more, since it may be for an account the pass doesn't hold.
    func refresh(finished: @escaping () -> Void) {
        guard !model.refreshing else {
            refreshAgain = true
            return
        }
        model.refreshing = true
        let sources = sources
        Task {
            await withTaskGroup(of: (UUID, ProviderUsage).self) { group in
                for (id, source) in sources { group.addTask { (id, await source.fetch()) } }
                // As they arrive: a signed-out agy can take 35 s, and the other accounts shouldn't wait for it.
                for await (id, result) in group { apply(result, to: id) }
            }
            model.refreshedAt = Date()
            model.refreshing = false
            finished()
            if refreshAgain {
                refreshAgain = false
                refresh(finished: finished)
            }
        }
    }

    private func apply(_ fetched: ProviderUsage, to id: UUID) {
        guard model.accounts.contains(where: { $0.id == id }) else { return } // removed while fetching
        var result = fetched
        // Preserve last good quota values during temporary provider failures.
        if result.error != nil, !result.needsConnection, let old = model.usage[id] {
            result.session = result.session ?? old.session
            result.weekly = result.weekly ?? old.weekly
            result.updatedAt = result.updatedAt ?? old.updatedAt
        }
        model.usage[id] = result
        resultApplied()
    }
}
