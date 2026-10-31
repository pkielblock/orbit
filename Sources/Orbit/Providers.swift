import Foundation

/// Fetches usage for one provider. Implementations must be cheap: no polling, no long-lived state.
protocol UsageSource {
    var provider: Provider { get }
    func fetch() async -> ProviderUsage
}

enum UsageError: Error, CustomStringConvertible {
    case missing(String)
    case http(Int)
    case badData(String)

    var description: String {
        switch self {
        case .missing(let what): return String(localized: "\(NSLocalizedString(what, comment: "")) not found")
        case .http(let code): return "HTTP \(code)"
        case .badData(let what): return String(localized: "unexpected \(NSLocalizedString(what, comment: ""))")
        }
    }
}

// MARK: - Claude

/// Reads the Claude Code OAuth token and asks Anthropic for the same usage numbers /usage shows.
/// Endpoint is undocumented; it may change.
actor ClaudeSource: UsageSource {
    let provider = Provider.claude
    private let session: URLSession
    private let tokenReader: () throws -> String
    private let now: () -> Date
    private var nextFetchAt = Date.distantPast
    private var lastResult: ProviderUsage?
    private var lastGood: ProviderUsage?
    private var rateLimitFailures = 0
    private var inFlight: Task<ProviderUsage, Never>?

    init(session: URLSession = AccountHTTP.session,
         tokenReader: @escaping () throws -> String = ClaudeCredentials.accessToken,
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.tokenReader = tokenReader
        self.now = now
    }

    func fetch() async -> ProviderUsage {
        if let inFlight { return await inFlight.value }
        if now() < nextFetchAt, let lastResult { return lastResult }
        let task = Task { await self.load() }
        inFlight = task
        let result = await task.value
        lastResult = result
        inFlight = nil
        return result
    }

    private func load() async -> ProviderUsage {
        do {
            let token = try tokenReader()
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                rateLimitFailures += 1
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                nextFetchAt = now().addingTimeInterval(Self.retryDelay(header, failures: rateLimitFailures, now: now()))
                return failure(String(localized: "Usage endpoint rate limited; retry after \(Format.clockTime(nextFetchAt))"))
            }
            if status == 401 || status == 403 {
                return failure(String(localized: "Claude sign-in expired or lacks usage access"), needsConnection: true)
            }
            guard status == 200 else { throw UsageError.http(status) }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageError.badData("response")
            }
            let sessionWindow = window(root["five_hour"])
            let weekly = window(root["seven_day"])
            guard sessionWindow != nil || weekly != nil else { throw UsageError.badData("quota windows") }
            let result = ProviderUsage(provider: provider, session: sessionWindow, weekly: weekly, updatedAt: now())
            lastGood = result
            rateLimitFailures = 0
            nextFetchAt = now().addingTimeInterval(300)
            return result
        } catch UsageError.missing {
            return failure(String(localized: "Claude login not found"), needsConnection: true)
        } catch {
            // Never surface response bodies, credentials or local paths in errors.
            return failure((error as? UsageError)?.description ?? String(localized: "Could not fetch Claude usage"))
        }
    }

    private func failure(_ message: String, needsConnection: Bool = false) -> ProviderUsage {
        var result = needsConnection ? ProviderUsage(provider: provider) : lastGood ?? ProviderUsage(provider: provider)
        result.error = message
        result.needsConnection = needsConnection
        if needsConnection { lastGood = nil }
        return result
    }

    /// A zero, invalid or absent header must never cause an immediate retry loop.
    static func retryDelay(_ header: String?, failures: Int, now: Date) -> TimeInterval {
        let backoff = min(300 * pow(2, Double(min(max(failures - 1, 0), 4))), 3600)
        guard let header else { return backoff }
        if let seconds = Double(header), seconds.isFinite { return max(backoff, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return max(backoff, formatter.date(from: header)?.timeIntervalSince(now) ?? 0)
    }

    private func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue,
              percent.isFinite else { return nil }
        return UsageWindow(usedPercent: percent, resetsAt: Dates.parse(dict["resets_at"]))
    }
}

enum AccountHTTP {
    // Authentication is confidential; retain neither cookies nor quota responses on disk.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

enum ClaudeCredentials {
    static func accessToken() throws -> String {
        // CONFIDENTIAL: provider-owned OAuth credentials remain in memory only.
        var found = false
        defer { UsageAudit.record(provider: .claude, success: found) }
        // Keychain first (macOS default), then the provider-owned credentials file.
        if let raw = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
           let token = tokenFrom(json: raw) { found = true; return token }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        if let raw = try? String(contentsOf: root.appendingPathComponent(".credentials.json"), encoding: .utf8),
           let token = tokenFrom(json: raw) { found = true; return token }
        throw UsageError.missing("Claude login")
    }

    static func tokenFrom(json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}

// MARK: - Codex

/// Requests current account quotas through Codex; the CLI owns authentication and token refresh.
struct CodexSource: UsageSource {
    let provider = Provider.codex

    func fetch() async -> ProviderUsage {
        do {
            let result = try await Task.detached { try CodexAccount.read() }.value
            return try Self.usage(from: result)
        } catch UsageError.missing(let message) {
            return ProviderUsage(provider: provider, error: message, needsConnection: true)
        } catch {
            return ProviderUsage(provider: provider, error: (error as? UsageError)?.description ?? String(localized: "Could not fetch Codex account quotas"))
        }
    }

    static func usage(from result: [String: Any]) throws -> ProviderUsage {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else {
            throw UsageError.badData("Codex quota response")
        }
        func window(_ value: Any?) -> UsageWindow? {
            guard let dict = value as? [String: Any],
                  let percent = (dict["usedPercent"] as? NSNumber)?.doubleValue,
                  percent.isFinite else { return nil }
            return UsageWindow(usedPercent: percent, resetsAt: Dates.parse(dict["resetsAt"]))
        }
        let primary = limits["primary"] as? [String: Any]
        let secondary = limits["secondary"] as? [String: Any]
        // A weekly-only response must not appear in the session meter.
        var session: UsageWindow?
        var weekly: UsageWindow?
        for (index, dict) in [primary, secondary].enumerated() {
            guard let dict else { continue }
            if let minutes = (dict["windowDurationMins"] as? NSNumber)?.intValue {
                if minutes >= 10080 { weekly = window(dict) }
                else { session = window(dict) }
            } else if index == 0 { session = window(dict) }
            else { weekly = window(dict) }
        }
        guard session != nil || weekly != nil else { throw UsageError.badData("Codex quota windows") }
        return ProviderUsage(provider: .codex, session: session, weekly: weekly, updatedAt: Date())
    }
}

// MARK: - Antigravity

/// Runs the Antigravity CLI's `/usage` command (`agy -p /usage`), which prints its quota table:
/// model group, window, remaining percent, reset time, tab-separated. agy handles its own login.
struct AntigravitySource: UsageSource {
    let provider = Provider.antigravity

    func fetch() async -> ProviderUsage {
        guard let agy = ProviderTools.executable("agy") else {
            return ProviderUsage(provider: provider, error: String(localized: "agy not found"), needsConnection: true)
        }
        guard let out = Shell.run(agy, ["-p", "/usage", "--print-timeout", "30s"], timeout: 35) else {
            return ProviderUsage(provider: provider, error: String(localized: "agy /usage failed; check sign-in in Antigravity"), needsConnection: true)
        }
        var session: UsageWindow?
        var weekly: UsageWindow?
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 4, cols[2].hasSuffix("%"), let remaining = Double(cols[2].dropLast()) else { continue }
            let window = UsageWindow(usedPercent: 100 - remaining, resetsAt: Dates.parse(cols[3]))
            if cols[1].contains("Five Hour") { session = busier(session, window) }
            if cols[1].contains("Weekly") { weekly = busier(weekly, window) }
        }
        guard session != nil || weekly != nil else {
            return ProviderUsage(provider: provider, error: String(localized: "no quota in agy output"), updatedAt: Date())
        }
        return ProviderUsage(provider: provider, session: session, weekly: weekly, error: nil, updatedAt: Date())
    }

    /// Each window is reported per model group; keep the most used one, since it blocks first.
    private func busier(_ current: UsageWindow?, _ next: UsageWindow) -> UsageWindow {
        guard let current, (current.usedPercent ?? 0) >= (next.usedPercent ?? 0) else { return next }
        return current
    }
}

// MARK: - Helpers

enum Shell {
    /// Runs a tool and returns stdout, or nil on failure. Used only for fixed tool paths.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let expiry = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum UsageAudit {
    /// Credential/account access status only; never log account identifiers, paths, tokens or quotas.
    static func record(provider: Provider, success: Bool) {
        let event: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event_id": UUID().uuidString,
            "event_type": "data.restricted.access",
            "severity": success ? "INFO" : "WARNING",
            "actor": ["id": "orbit", "type": "service_account"],
            "action": ["type": "READ", "outcome": success ? "success" : "failure"],
            "resource": ["id": provider.logoName, "type": "provider_account"],
            "context": ["environment": "desktop", "service": "Orbit"],
            "metadata": [:]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
}

enum Dates {
    static func parse(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
