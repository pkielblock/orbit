import Foundation
import Darwin

enum ProviderTools {
    static func executable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { "\($0)/\(name)" }
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A short-lived stdio client: no threads, prompts, conversations or credential copies.
enum CodexAccount {
    static func read(executable: String? = ProviderTools.executable("codex"), timeout: TimeInterval = 25) throws -> [String: Any] {
        var success = false
        defer { UsageAudit.record(provider: .codex, success: success) }
        guard let executable else { throw UsageError.missing("Install Codex CLI, then sign in with ChatGPT") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "-c", "analytics.enabled=false"]
        // The app server must not inherit a project's working directory/configuration.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data()

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        func response(_ id: Int) throws -> [String: Any] {
            while ProcessInfo.processInfo.systemUptime < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (message["id"] as? NSNumber)?.intValue == id else { continue }
                    if message["error"] != nil {
                        // Server errors can include account details; show only a fixed message.
                        throw UsageError.badData("Codex request failed; check login or update Codex CLI")
                    }
                    guard let result = message["result"] as? [String: Any] else {
                        throw UsageError.badData("Codex account response")
                    }
                    return result
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
                let ready = poll(&descriptor, 1, remaining)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { throw UsageError.badData("Codex account request timed out") }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw UsageError.badData("Codex app server exited before replying") }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 1_048_576 else { throw UsageError.badData("oversized Codex account response") }
            }
            throw UsageError.badData("Codex account request timed out")
        }

        try send(["id": 0, "method": "initialize", "params": [
            "clientInfo": ["name": "orbit", "title": "Orbit", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"]
        ]])
        _ = try response(0)
        try send(["method": "initialized"])
        try send(["id": 1, "method": "account/read", "params": ["refreshToken": false]])
        // PII: account/read can contain an email; inspect only its type, never retain or log it.
        let account = try response(1)["account"] as? [String: Any]
        guard account?["type"] as? String == "chatgpt" else {
            throw UsageError.missing("Sign in to Codex with ChatGPT; API keys have no subscription quotas")
        }
        try send(["id": 2, "method": "account/rateLimits/read"])
        let result = try response(2)
        success = true
        return result
    }
}
