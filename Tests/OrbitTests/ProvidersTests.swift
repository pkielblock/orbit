import XCTest
@testable import Orbit

final class ProvidersTests: XCTestCase {
    func testMiseDiscoveryWithoutShellPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for (data, environment) in [
            (home.appendingPathComponent(".local/share/mise"), [:]),
            (home.appendingPathComponent("custom-mise"), ["MISE_DATA_DIR": home.appendingPathComponent("custom-mise").path]),
            (home.appendingPathComponent("data/mise"), ["XDG_DATA_HOME": home.appendingPathComponent("data").path])
        ] {
            let shims = data.appendingPathComponent("shims")
            try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
            let name = "orbit-test-provider"
            let shim = shims.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: shim, atomically: true, encoding: .utf8)
            XCTAssertNil(ProviderTools.executable(name, home: home.path, environment: environment))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            XCTAssertEqual(ProviderTools.executable(name, home: home.path, environment: environment), shim.path)
            try FileManager.default.removeItem(at: data)
        }
    }

    func testLiveCodexBucketsAndWeeklyOnlyWindow() throws {
        let result: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 2_000_000_000],
                "secondary": ["usedPercent": 34, "windowDurationMins": 10080]
            ]]
        ]
        let usage = try CodexSource.usage(from: result)
        XCTAssertEqual(usage.session?.usedPercent, 12)
        XCTAssertEqual(usage.weekly?.usedPercent, 34)
        XCTAssertEqual(usage.session?.resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
        let weeklyOnly = try CodexSource.usage(from: ["rateLimits": [
            "primary": ["usedPercent": 55, "windowDurationMins": 10080], "secondary": NSNull()
        ]])
        XCTAssertNil(weeklyOnly.session)
        XCTAssertEqual(weeklyOnly.weekly?.usedPercent, 55)
        XCTAssertThrowsError(try CodexSource.usage(from: ["rateLimits": [:]]))
        XCTAssertThrowsError(try CodexSource.usage(from: [:]))
    }

    func testRetryAfterZeroDatesAndRepeatedLimits() {
        let now = Date(timeIntervalSince1970: 0)
        for header in [nil, "0", "-10", "invalid", "nan", "inf"] as [String?] {
            XCTAssertEqual(ClaudeSource.retryDelay(header, failures: 1, now: now), 300)
        }
        XCTAssertEqual(ClaudeSource.retryDelay("1200", failures: 1, now: now), 1200)
        XCTAssertEqual(ClaudeSource.retryDelay("Thu, 01 Jan 1970 00:20:00 GMT", failures: 1, now: now), 1200)
        XCTAssertEqual(ClaudeSource.retryDelay(nil, failures: 2, now: now), 600)
        XCTAssertEqual(ClaudeSource.retryDelay(nil, failures: 50, now: now), 3600)
    }

    func testClaudeCachesSuccessAndBacksOffWithStaleQuota() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = TestClock()
        QuotaURLProtocol.reset()
        let source = ClaudeSource(session: session, tokenReader: { "test-token" }, now: { clock.date })
        async let first = source.fetch()
        async let simultaneous = source.fetch()
        let results = await [first, simultaneous]
        XCTAssertEqual(results[0].session?.usedPercent, 23)
        XCTAssertEqual(results[1].session?.usedPercent, 23)
        XCTAssertEqual(QuotaURLProtocol.requests, 1)
        _ = await source.fetch()
        XCTAssertEqual(QuotaURLProtocol.requests, 1)
        clock.date = clock.date.addingTimeInterval(300)
        let limited = await source.fetch()
        XCTAssertNotNil(limited.error)
        XCTAssertFalse(limited.needsConnection)
        XCTAssertEqual(limited.session?.usedPercent, 23)
        XCTAssertEqual(limited.updatedAt, results[0].updatedAt)
        _ = await source.fetch()
        XCTAssertEqual(QuotaURLProtocol.requests, 2)
        clock.date = clock.date.addingTimeInterval(299)
        _ = await source.fetch()
        XCTAssertEqual(QuotaURLProtocol.requests, 2)
        clock.date = clock.date.addingTimeInterval(1)
        _ = await source.fetch()
        XCTAssertEqual(QuotaURLProtocol.requests, 3)
    }

    func testMissingClaudeCredentialsNeedConnection() async {
        let source = ClaudeSource(tokenReader: { throw UsageError.missing("login") })
        let result = await source.fetch()
        XCTAssertTrue(result.needsConnection)
        XCTAssertNil(result.session)
        XCTAssertNil(result.updatedAt)
    }

    func testExpiredClaudeLoginClearsPreviousAccountQuota() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = TestClock()
        QuotaURLProtocol.reset(failureStatus: 401)
        let source = ClaudeSource(session: session, tokenReader: { "test-token" }, now: { clock.date })
        _ = await source.fetch()
        clock.date = clock.date.addingTimeInterval(300)
        let expired = await source.fetch()
        XCTAssertTrue(expired.needsConnection)
        XCTAssertNil(expired.session)
        XCTAssertNil(expired.weekly)
        XCTAssertNil(expired.updatedAt)
    }

    func testCredentialCommandsCannotBlockRefreshForever() {
        let start = Date()
        XCTAssertNil(Shell.run("/bin/sleep", ["30"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Runs a shell script that leaves a `sleep` behind holding stdout, and kills that child afterwards. Returns the seconds taken.
    private func runLeavingChild(_ script: String, timeout: TimeInterval, check: (String?) -> Void) throws -> TimeInterval {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let start = Date()
        let output = Shell.run("/bin/sh", ["-c", "sleep 20 & echo $! > '\(pidFile.path)'; \(script)"], timeout: timeout)
        let elapsed = Date().timeIntervalSince(start)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        XCTAssertEqual(kill(pid, 0), 0, "the child must still hold the pipe when run returns")
        check(output)
        return elapsed
    }

    func testChildHoldingThePipeCannotOutliveTheTimeout() throws {
        // The tool hangs too: killed at the timeout, so it counts as failed.
        let hung = try runLeavingChild("wait", timeout: 0.5) { XCTAssertNil($0) }
        XCTAssertGreaterThanOrEqual(hung, 0.5)
        XCTAssertLessThan(hung, 3)
        // The tool succeeded and left: its output counts, and the read stops soon after the exit instead of at the timeout.
        XCTAssertLessThan(try runLeavingChild("printf done; exit 0", timeout: 10) { XCTAssertEqual($0, "done") }, 3)
        // More than a pipe holds, written while the child keeps the pipe open: all of it is read.
        XCTAssertLessThan(try runLeavingChild("yes | head -c 200000; exit 0", timeout: 10) { XCTAssertEqual($0?.count, 200_000) }, 3)
    }

    func testToolClosingItsOutputBeforeExitingKeepsItsResult() {
        XCTAssertEqual(Shell.run("/bin/sh", ["-c", "printf x; exec 1>&-; sleep 0.05; exit 0"], timeout: 5), "x")
        XCTAssertNil(Shell.run("/bin/sh", ["-c", "printf x; exec 1>&-; sleep 0.05; exit 3"], timeout: 5))
        // Closed its output and hung: still killed at the timeout.
        let start = Date()
        XCTAssertNil(Shell.run("/bin/sh", ["-c", "printf x; exec 1>&-; exec sleep 30"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testShellReadsLongOutputAndReportsFailure() {
        XCTAssertEqual(Shell.run("/bin/sh", ["-c", "yes | head -c 200000"], timeout: 5)?.count, 200_000)
        XCTAssertEqual(Shell.run("/bin/sh", ["-c", "printf quick"], timeout: 5), "quick")
        XCTAssertNil(Shell.run("/bin/sh", ["-c", "printf partial; exit 3"], timeout: 5))
    }

    func testCodexHandshakeNotificationsAndLiveResult() throws {
        let executable = try fixture(account: #"{"type":"chatgpt","email":"unused@example.test"}"#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let result = try CodexAccount.read(executable: executable.path, timeout: 2)
        XCTAssertEqual(try CodexSource.usage(from: result).session?.usedPercent, 37)
    }

    func testCodexMissingAccountAPIKeyAndTimeout() throws {
        XCTAssertThrowsError(try CodexAccount.read(executable: nil))
        for account in ["null", #"{"type":"apiKey"}"#] {
            let executable = try fixture(account: account)
            defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
            XCTAssertThrowsError(try CodexAccount.read(executable: executable.path, timeout: 2)) { error in
                guard case UsageError.missing = error else { return XCTFail("Expected connection error") }
            }
        }
        let executable = try fixture(account: "null", hang: true)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let start = Date()
        XCTAssertThrowsError(try CodexAccount.read(executable: executable.path, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private func fixture(account: String, hang: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        let script = hang ? "#!/bin/sh\nwhile :; do :; done\n" : """
        #!/bin/sh
        IFS= read -r line
        case "$line" in *initialize*) ;; *) exit 1;; esac
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r line
        case "$line" in *initialized*) ;; *) exit 1;; esac
        IFS= read -r line
        case "$line" in *account/read*) ;; *) exit 1;; esac
        printf '%s\\n' '{"id":1,"result":{"account":\(account)}}'
        IFS= read -r line
        case "$line" in *account/rateLimits/read*) ;; *) exit 1;; esac
        printf '%s\\n' '{"method":"account/updated","params":{}}'
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":300}}}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000_000)
}

private final class QuotaURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var failureStatus = 429
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset(failureStatus: Int = 429) {
        lock.lock(); count = 0; Self.failureStatus = failureStatus; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let count = Self.count
        let failureStatus = Self.failureStatus
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 200 : failureStatus,
                                       httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"five_hour":{"utilization":23},"seven_day":{"utilization":45}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
