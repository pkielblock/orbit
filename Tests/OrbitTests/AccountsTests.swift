import XCTest
@testable import Orbit

final class AccountsTests: XCTestCase {
    private let home = "/Users/example"

    private func encode(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }

    private func entry(_ provider: String = "claude", name: String = "Work", folder: Any? = "/Users/example/.claude-work") -> [String: Any] {
        var value: [String: Any] = ["id": UUID().uuidString, "provider": provider, "name": name]
        if let folder { value["folder"] = folder }
        return value
    }

    private var defaultsOnly: [Account] { Provider.allCases.map { Account.defaultAccount($0) } }

    func testCorruptDataKeepsDefaults() throws {
        XCTAssertEqual(AccountStore.decode(nil, home: home), defaultsOnly)
        XCTAssertEqual(AccountStore.decode(Data("not json".utf8), home: home), defaultsOnly)
        XCTAssertEqual(AccountStore.decode(Data(#"{"a":1}"#.utf8), home: home), defaultsOnly)
    }

    func testInvalidEntriesAreDroppedAndValidOnesKept() throws {
        let data = try encode([
            entry(),
            entry(name: "Relative", folder: ".claude-other"),
            entry(name: "Tilde", folder: "~/.claude-other"),
            entry(name: "   ", folder: "/Users/example/.claude-blank"),
            entry("no-such-provider", folder: "/Users/example/.other"),
            ["id": "not-a-uuid", "provider": "claude", "name": "Bad", "folder": "/Users/example/.bad"],
            entry(name: "Twin", folder: "/Users/example/.claude-work"),
            entry(name: "Provider default", folder: "/Users/example/.claude"),
            entry("antigravity", name: "Home", folder: home)
        ])
        let accounts = AccountStore.decode(data, home: home)
        XCTAssertEqual(accounts.filter { $0.folder != nil }.map(\.name), ["Work"])
        for provider in Provider.allCases {
            XCTAssertEqual(accounts.filter { $0.provider == provider && $0.folder == nil }.count, 1)
            XCTAssertEqual(accounts.first { $0.provider == provider }?.folder, nil, "default comes first")
        }
    }

    func testDefaultAccountCanBeRenamedAndStaysSingle() throws {
        let renamed = Account.defaultAccount(.codex, name: "Personal")
        let extra = Account(id: UUID(), provider: .codex, name: "Second default", folder: nil)
        let accounts = AccountStore.sanitize([renamed, extra], home: home)
        XCTAssertEqual(accounts.filter { $0.provider == .codex }, [renamed])
    }

    func testIdsAreUniqueAcrossProvidersAndDefaultIdsReserved() {
        let codexDefault = Account.defaultAccount(.codex).id
        let shared = UUID()
        let accounts = AccountStore.sanitize([
            Account(id: codexDefault, provider: .claude, name: "Stolen", folder: "/a"),
            Account(id: shared, provider: .claude, name: "First", folder: "/b"),
            Account(id: shared, provider: .codex, name: "Second", folder: "/c")
        ], home: home)
        XCTAssertEqual(accounts.filter { $0.folder != nil }.map(\.name), ["First"])
        XCTAssertEqual(Set(accounts.map(\.id)).count, accounts.count)
        XCTAssertEqual(accounts.first { $0.id == codexDefault }?.provider, .codex)
    }

    func testRoundTrip() throws {
        let suite = "orbit-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let added = Account(id: UUID(), provider: .claude, name: "Work", folder: "/Users/example/.claude-work")
        AccountStore.save(AccountStore.sanitize([added], home: home), defaults: defaults)
        XCTAssertTrue(AccountStore.load(defaults: defaults, home: home).contains(added))
    }

    func testFolderAlreadyUsedComparesRealPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("work")
        let link = root.appendingPathComponent("link")
        let defaultFolder = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let accounts = [Account.defaultAccount(.claude), Account(id: UUID(), provider: .claude, name: "Work", folder: real.path)]
        XCTAssertTrue(AccountStore.folderUsed(real.path, provider: .claude, in: accounts, home: root.path))
        XCTAssertTrue(AccountStore.folderUsed(real.path + "/", provider: .claude, in: accounts, home: root.path))
        XCTAssertTrue(AccountStore.folderUsed(link.path, provider: .claude, in: accounts, home: root.path))
        XCTAssertTrue(AccountStore.folderUsed(defaultFolder.path, provider: .claude, in: accounts, home: root.path))
        XCTAssertFalse(AccountStore.folderUsed(root.appendingPathComponent("free").path, provider: .claude, in: accounts, home: root.path))
        XCTAssertFalse(AccountStore.folderUsed(real.path, provider: .codex, in: accounts, home: root.path), "per provider")
    }

    func testNameUsedIgnoresCaseAndItself() {
        let work = Account(id: UUID(), provider: .claude, name: "Work", folder: "/a")
        let accounts = [Account.defaultAccount(.claude, name: "Personal"), work]
        XCTAssertTrue(AccountStore.nameUsed(" work ", provider: .claude, in: accounts))
        XCTAssertFalse(AccountStore.nameUsed("Work", provider: .claude, in: accounts, except: work.id))
        XCTAssertFalse(AccountStore.nameUsed("Work", provider: .codex, in: accounts))
    }

    func testNewFolderUsesTheIdNotAName() {
        let id = UUID()
        XCTAssertEqual(AccountStore.newFolder(.codex, id: id, home: home),
                       "\(home)/Library/Application Support/Orbit/codex/\(id.uuidString)")
    }

    func testCreatedFolderIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("claude/id").path
        try AccountStore.createFolder(path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    /// Expected suffixes come from `printf %s <path> | shasum -a 256`, not from this code.
    func testClaudeKeychainServiceNames() {
        XCTAssertEqual(ClaudeCredentials.keychainService(folder: nil), "Claude Code-credentials")
        XCTAssertEqual(ClaudeCredentials.keychainService(folder: "/Users/example/.claude-work"), "Claude Code-credentials-dd1118a7")
        XCTAssertEqual(ClaudeCredentials.keychainService(folder: "/Users/example/.claude"), "Claude Code-credentials-402b469b")
    }

    func testAddedClaudeAccountReadsItsOwnKeychainItem() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"added-token"}}"#
        var asked: [String] = []
        let token = try ClaudeCredentials.accessToken(folder: "/Users/example/.claude-work", home: home) { service in
            asked.append(service)
            return json
        }
        XCTAssertEqual(token, "added-token")
        XCTAssertEqual(asked, [ClaudeCredentials.keychainService(folder: "/Users/example/.claude-work")])
    }

    func testDefaultClaudeAccountKeepsUnsuffixedItemThenFile() throws {
        var asked: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ClaudeCredentials.accessToken(home: root.path) { asked.append($0); return nil })
        XCTAssertEqual(asked, ["Claude Code-credentials"])
        let folder = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"file-token"}}"#.write(to: folder.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ClaudeCredentials.accessToken(home: root.path) { _ in nil }, "file-token")
    }

    func testAddedClaudeAccountFallsBackToItsOwnFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"own-file"}}"#.write(to: folder.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ClaudeCredentials.accessToken(folder: folder.path, home: home) { _ in nil }, "own-file")
    }

    func testSignInCommands() {
        func found(_ tool: String) -> String? { "/bin/\(tool)" }
        XCTAssertEqual(Account.defaultAccount(.claude).signInCommand(executable: found), "'/bin/claude' auth login")
        XCTAssertEqual(Account(id: UUID(), provider: .claude, name: "W", folder: "/a b/it's").signInCommand(executable: found),
                       #"CLAUDE_CONFIG_DIR='/a b/it'\''s' '/bin/claude' auth login"#)
        XCTAssertEqual(Account(id: UUID(), provider: .codex, name: "W", folder: "/c").signInCommand(executable: { _ in nil }),
                       "CODEX_HOME='/c' codex login")
        XCTAssertEqual(Account(id: UUID(), provider: .antigravity, name: "W", folder: "/d").signInCommand(executable: found),
                       "HOME='/d' '/bin/agy'")
    }

    func testToolsGetTheAccountEnvironment() throws {
        XCTAssertEqual(Shell.run("/bin/sh", ["-c", "printf %s \"$HOME\""], environment: ["HOME": "/tmp/orbit-account"]), "/tmp/orbit-account")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A fake codex that answers only when CODEX_HOME reached it.
        let executable = directory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        [ "$CODEX_HOME" = "\(directory.path)" ] || exit 1
        read -r line; printf '%s\\n' '{"id":0,"result":{}}'
        read -r line; read -r line; printf '%s\\n' '{"id":1,"result":{"account":{"type":"chatgpt"}}}'
        read -r line; printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = try CodexAccount.read(executable: executable.path, folder: directory.path, timeout: 2)
        XCTAssertEqual(try CodexSource.usage(from: result).session?.windowDuration, 18_000)
        XCTAssertThrowsError(try CodexAccount.read(executable: executable.path, folder: directory.path + "-missing", timeout: 2)) { error in
            guard case UsageError.missing(let message) = error else { return XCTFail("Expected connection error") }
            XCTAssertFalse(message.contains("/"), "errors never hold paths")
        }
    }

    func testSignedOutAntigravityReachesSignIn() throws {
        // What agy does signed out: killed at the timeout, so no output; or a clean exit that only asks for login.
        for output in [nil, "Authentication required. Please visit the URL to log in:\n"] as [String?] {
            let usage = AntigravitySource.usage(from: output)
            XCTAssertTrue(usage.needsConnection)
            XCTAssertNotNil(usage.error)
        }
        XCTAssertFalse(AntigravitySource.usage(from: "nothing useful").needsConnection)
        XCTAssertNotNil(AntigravitySource.usage(from: "nothing useful").error)
        let usage = AntigravitySource.usage(from: "Models\tFive Hour\t80%\t2030-01-01T00:00:00Z\nModels\tFive Hour\t60%\t2030-01-01T00:00:00Z\nModels\tWeekly\t90%\t2030-01-01T00:00:00Z\n")
        XCTAssertEqual(usage.session?.usedPercent, 40, "the busiest group")
        XCTAssertEqual(usage.session?.windowDuration, 18_000)
        XCTAssertEqual(usage.weekly?.usedPercent, 10)
        XCTAssertFalse(usage.needsConnection)
        // The signed-out path through a real process killed at its timeout.
        XCTAssertTrue(AntigravitySource.usage(from: Shell.run("/bin/sleep", ["30"], timeout: 0.1)).needsConnection)
    }

    func testLogRoots() {
        let added = Account(id: UUID(), provider: .codex, name: "W", folder: "/w")
        let roots = AccountStore.logRoots([Account.defaultAccount(.claude), added, Account.defaultAccount(.antigravity)], home: home)
        XCTAssertEqual(roots[.claude], ["\(home)/.claude/projects"])
        XCTAssertEqual(roots[.codex], ["/w/sessions", "/w/archived_sessions"])
        XCTAssertNil(roots[.antigravity])
    }
}
