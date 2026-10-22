import AppKit
import CryptoKit
import Foundation

struct OrbitRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let digest: String?
        var browser_download_url: String? = nil
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var version: String { String(tag_name.dropFirst()) }
    var diskImage: Asset? {
        assets.first { $0.name == "Orbit-\(version).dmg" }
            ?? assets.first { $0.name.hasPrefix("Orbit-") && $0.name.hasSuffix(".dmg") && !$0.name.contains("/") }
    }

    static func components(_ version: String) -> [UInt]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = parts.compactMap { UInt($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let next = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(next.count, old.count) {
            let lhs = index < next.count ? next[index] : 0
            let rhs = index < old.count ? old[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    func update(from current: String) -> OrbitRelease? {
        guard tag_name.hasPrefix("v"), !draft, !prerelease,
              Self.isNewer(version, than: current), diskImage != nil else { return nil }
        return self
    }
}

enum UpdateFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum UpdateTools {
    static let repository = "pkielblock/orbit"

    static let curl = "/usr/bin/curl"

    /// Runs off the main actor. stderr is never surfaced or persisted.
    static func run(_ path: String, _ arguments: [String], timeout: Double = 120) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let expiry = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expiry.cancel()
        guard process.terminationStatus == 0 else {
            throw UpdateFailure.message(path == curl
                ? "GitHub request failed. Check your connection, then retry."
                : "Update preparation failed. Your current app is unchanged; retry the update.")
        }
        return data
    }

    static func latest() throws -> OrbitRelease {
        let data = try run(curl, ["-fsSL", "--proto", "=https", "-H", "Accept: application/vnd.github+json",
                                  "https://api.github.com/repos/\(repository)/releases/latest"])
        return try JSONDecoder().decode(OrbitRelease.self, from: data)
    }

    static func verifyDigest(_ data: Data, expected: String?) throws {
        let actual = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw UpdateFailure.message("Update checksum missing or invalid. Current app unchanged.") }
    }

    static func prepare(_ release: OrbitRelease, currentApp: URL) throws -> URL {
        let files = FileManager.default
        guard currentApp.pathExtension == "app", currentApp.path != "/",
              files.isWritableFile(atPath: currentApp.path),
              files.isWritableFile(atPath: currentApp.deletingLastPathComponent().path),
              !currentApp.path.contains("/AppTranslocation/") else {
            throw UpdateFailure.message("Move Orbit to a writable Applications folder before updating.")
        }
        guard let asset = release.diskImage, let url = asset.browser_download_url,
              url.hasPrefix("https://github.com/\(repository)/releases/download/") else {
            throw UpdateFailure.message("Release has no Orbit disk image.")
        }
        let staging = currentApp.deletingLastPathComponent().appendingPathComponent(".Orbit-update-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? files.removeItem(at: staging) } }
        let image = staging.appendingPathComponent("release.dmg")
        _ = try run(curl, ["-fsSL", "--proto", "=https", "--output", image.path, url], timeout: 600)
        try verifyDigest(Data(contentsOf: image, options: .mappedIfSafe), expected: asset.digest)
        let mount = staging.appendingPathComponent("mount")
        try files.createDirectory(at: mount, withIntermediateDirectories: false)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        _ = try run("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path])
        let source = mount.appendingPathComponent("Orbit.app")
        guard let bundle = Bundle(url: source), bundle.bundleIdentifier == "dev.kielblock.orbit",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              files.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/Orbit").path) else {
            throw UpdateFailure.message("Downloaded app does not match the release. Current app unchanged.")
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        let stagedApp = staging.appendingPathComponent("Orbit.app")
        _ = try run("/usr/bin/ditto", [source.path, stagedApp.path])
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        try files.removeItem(at: image)
        guard let helper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
            throw UpdateFailure.message("Update helper missing. Reinstall Orbit from Releases.")
        }
        try files.copyItem(at: helper, to: staging.appendingPathComponent("install-update.sh"))
        prepared = true
        return staging
    }

    static func audit(_ action: String, outcome: String) {
        // INTERNAL: log operation metadata only, never credentials, paths or provider data.
        let entry: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
            "event_id": UUID().uuidString, "event_type": "app.update.\(action)", "severity": "INFO",
            "actor": ["id": "local-user", "type": "user"],
            "action": ["type": "UPDATE", "outcome": outcome],
            "resource": ["id": "dev.kielblock.orbit", "type": "application"],
            "context": ["service": "orbit", "environment": "desktop"]]
        if let data = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: data, encoding: .utf8) { print(line) }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var release: OrbitRelease?
    @Published private(set) var busy = false
    @Published private(set) var message = "Updates checked daily"
    private let currentVersion: String
    private var lastCheck: Date?

    init(currentVersion: String? = nil) {
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 86_400 || now < lastCheck
    }

    func checkIfDue(force: Bool = false) {
        guard !busy, force || Self.isDue(lastCheck: lastCheck) else { return }
        busy = true
        message = "Checking for updates…"
        lastCheck = Date()
        Task {
            do {
                let latest = try await Task.detached { try UpdateTools.latest() }.value
                release = latest.update(from: currentVersion)
                message = release.map { "Version \($0.version) available" } ?? "Orbit is up to date"
            } catch {
                message = (error as? UpdateFailure)?.localizedDescription ?? "Could not read release information. Retry the check."
            }
            busy = false
        }
    }

    func install() {
        guard !busy, let release else { return }
        busy = true
        message = "Downloading update…"
        let appURL = Bundle.main.bundleURL
        UpdateTools.audit("install", outcome: "started")
        Task {
            var staging: URL?
            do {
                let directory = try await Task.detached { try UpdateTools.prepare(release, currentApp: appURL) }.value
                staging = directory
                let helper = Process()
                helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                helper.arguments = [directory.appendingPathComponent("install-update.sh").path,
                                    String(ProcessInfo.processInfo.processIdentifier), appURL.path, directory.path]
                helper.standardInput = FileHandle.nullDevice
                try helper.run()
                NSApp.terminate(nil)
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                UpdateTools.audit("install", outcome: "failure")
                message = (error as? UpdateFailure)?.localizedDescription ?? "Update failed. Current app unchanged; retry."
                busy = false
            }
        }
    }
}
