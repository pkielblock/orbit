import XCTest
@testable import Orbit

final class TokenLogsTests: XCTestCase {
    private var root: URL!
    private let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = saoPaulo; return c }
    /// 2026-11-05 15:00 in UTC, 12:00 in Sao Paulo.
    private let now = Date(timeIntervalSince1970: 1_793_890_800)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func claudeLine(_ id: String, at date: Date, input: Int = 10, output: Int = 20, cacheWrite: Int = 30, cacheRead: Int = 1000) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp(date))","requestId":"r\#(id)","message":{"id":"m\#(id)","content":[{"type":"text","text":"secret"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead)}}}"#
    }

    private func codexLine(total: Int, cached: Int, at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total),"cached_input_tokens":\#(cached)}}}}"#
    }

    @discardableResult
    private func write(_ lines: [String], to relative: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now], ofItemAtPath: url.path)
        return url
    }

    private func scan(_ provider: Provider, roots: [String], scanner: TokenScanner = TokenScanner(), sessionStart: Date? = nil) -> ProviderTokens {
        let starts = sessionStart.map { [provider: $0] } ?? [:]
        return scanner.scanNow(roots: [provider: roots], sessionStarts: starts, now: now, calendar: calendar)[provider]!
    }

    func testClaudeDedupesAcrossFilesIncludingSubagents() throws {
        let date = now.addingTimeInterval(-60)
        try write([claudeLine("a", at: date), claudeLine("a", at: date)], to: "projects/one/s.jsonl")
        try write([claudeLine("a", at: date), claudeLine("b", at: date)], to: "projects/two/sub/agents/t.jsonl")
        let tokens = scan(.claude, roots: [root.appendingPathComponent("projects").path])
        XCTAssertEqual(tokens.session, 120, "two unique messages of 60")
        XCTAssertEqual(tokens.week, 120)
    }

    func testSameMessageIdWithAnotherRequestCountsSeparately() throws {
        let date = now.addingTimeInterval(-60)
        let other = claudeLine("a", at: date).replacingOccurrences(of: #""requestId":"ra""#, with: #""requestId":"rz""#)
        try write([claudeLine("a", at: date), other], to: "projects/s.jsonl")
        XCTAssertEqual(scan(.claude, roots: [root.appendingPathComponent("projects").path]).week, 120)
    }

    func testSharedSymlinkedRootCountedOnce() throws {
        try write([claudeLine("a", at: now.addingTimeInterval(-60))], to: "real/projects/s.jsonl")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: second.appendingPathComponent("projects"),
                                                   withDestinationURL: root.appendingPathComponent("real/projects"))
        let scanner = TokenScanner()
        let tokens = scan(.claude, roots: [root.appendingPathComponent("real/projects").path, second.appendingPathComponent("projects").path], scanner: scanner)
        XCTAssertEqual(tokens.week, 60)
        XCTAssertEqual(scanner.filesRead, 1)

        // Codex has no ids to dedupe on, so this is the only protection there.
        try write([codexLine(total: 100, cached: 40, at: now.addingTimeInterval(-60))], to: "codex/sessions/2026/11/05/c.jsonl")
        let codexLink = root.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: codexLink, withDestinationURL: root.appendingPathComponent("codex"))
        XCTAssertEqual(scan(.codex, roots: [root.appendingPathComponent("codex/sessions").path, codexLink.appendingPathComponent("sessions").path]).week, 60)
    }

    func testCodexDeltasRepeatsDropsAndNullInfo() throws {
        let date = now.addingTimeInterval(-60)
        let null = #"{"timestamp":"\#(stamp(date))","payload":{"type":"token_count","info":null}}"#
        try write([
            codexLine(total: 100, cached: 40, at: date),  // +60
            null,
            codexLine(total: 100, cached: 40, at: date),  // repeated: nothing
            codexLine(total: 300, cached: 100, at: date), // +140
            codexLine(total: 50, cached: 0, at: date),    // dropped: new baseline, nothing
            codexLine(total: 80, cached: 0, at: date)     // +30
        ], to: "sessions/2026/11/05/c.jsonl")
        // Each file has its own running total.
        try write([codexLine(total: 10, cached: 0, at: date)], to: "archived_sessions/d.jsonl")
        let tokens = scan(.codex, roots: [root.appendingPathComponent("sessions").path, root.appendingPathComponent("archived_sessions").path])
        XCTAssertEqual(tokens.week, 240)
    }

    func testLocalDayBucketsAroundMidnight() throws {
        let midnight = calendar.startOfDay(for: now)
        try write([
            claudeLine("before", at: midnight.addingTimeInterval(-1)), // yesterday locally, today in UTC
            claudeLine("after", at: midnight)
        ], to: "p/s.jsonl")
        let tokens = scan(.claude, roots: [root.appendingPathComponent("p").path])
        XCTAssertEqual(tokens.days.count, 7)
        XCTAssertEqual(tokens.days.last?.day, midnight)
        XCTAssertEqual(tokens.days.last?.tokens, 60)
        XCTAssertEqual(tokens.days[5].tokens, 60)
        XCTAssertEqual(tokens.week, 120)
    }

    func testDayStartsCrossDST() {
        // New York leaves DST on 2026-11-01, so that day has 25 hours.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let starts = TokenLogs.dayStarts(now: now, calendar: newYork)
        XCTAssertEqual(starts.count, 7)
        let hours = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) / 3600 }
        XCTAssertEqual(hours.sorted(), [24, 24, 24, 24, 24, 25])
        XCTAssertEqual(starts, starts.map { newYork.startOfDay(for: $0) })
    }

    func testExcludesCacheReadsAndEventsOutsideTheWindow() throws {
        let weekStart = TokenLogs.dayStarts(now: now, calendar: calendar)[0]
        try write([
            claudeLine("in", at: now.addingTimeInterval(-60), input: 1, output: 2, cacheWrite: 3, cacheRead: 99_999),
            claudeLine("old", at: weekStart.addingTimeInterval(-1)),
            claudeLine("future", at: now.addingTimeInterval(60))
        ], to: "p/s.jsonl")
        // An old file is not even opened.
        try write([claudeLine("skipped", at: now.addingTimeInterval(-60))], to: "p/old.jsonl", modified: weekStart.addingTimeInterval(-1))
        let scanner = TokenScanner()
        let tokens = scan(.claude, roots: [root.appendingPathComponent("p").path], scanner: scanner)
        XCTAssertEqual(tokens.week, 6)
        XCTAssertEqual(tokens.session, 6)
        XCTAssertEqual(scanner.filesRead, 1)
    }

    func testSessionTotalStartsAtGivenWindow() throws {
        try write([claudeLine("early", at: now.addingTimeInterval(-7200)), claudeLine("late", at: now.addingTimeInterval(-60))], to: "p/s.jsonl")
        let path = root.appendingPathComponent("p").path
        XCTAssertEqual(scan(.claude, roots: [path], sessionStart: now.addingTimeInterval(-3600)).session, 60)
        XCTAssertEqual(scan(.claude, roots: [path], sessionStart: now.addingTimeInterval(-3 * 3600)).session, 120)
        XCTAssertEqual(scan(.claude, roots: [path]).session, 120, "rolling 5 hours when none given")
    }

    func testMalformedLinesAndMissingFolders() throws {
        let date = now.addingTimeInterval(-60)
        try write([
            "not json with \"usage\" in it",
            #"{"message":{"usage":"nope"},"requestId":"x"}"#,
            #"{"message":{"id":"noRequest","usage":{"input_tokens":5}},"timestamp":"\#(stamp(date))"}"#,
            #"{"requestId":"r","message":{"id":"m","usage":{"input_tokens":5}},"timestamp":"not a date"}"#,
            "",
            claudeLine("good", at: date),
            #"{"truncated":"usage"#
        ], to: "p/s.jsonl")
        XCTAssertEqual(scan(.claude, roots: [root.appendingPathComponent("p").path]).week, 60)
        let missing = scan(.claude, roots: [root.appendingPathComponent("nowhere").path])
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(missing.days.count, 7)
    }

    func testLinesSplitAcrossChunksAndAFinalLineWithoutNewline() throws {
        let date = now.addingTimeInterval(-60)
        let padding = #"{"type":"user","filler":""# + String(repeating: "x", count: 3 << 19) + #""}"#
        let url = root.appendingPathComponent("p/s.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The usage line straddles the 1 MB chunk boundary; the last has no newline.
        let long = claudeLine("long", at: date).replacingOccurrences(of: "secret", with: String(repeating: "y", count: 1 << 21))
        let text = padding + "\n" + long + "\n" + claudeLine("last", at: date)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        XCTAssertEqual(scan(.claude, roots: [root.appendingPathComponent("p").path]).week, 120)
    }

    func testMarkerSkipsLinesBeforeParsing() throws {
        let url = try write(["a usage b", #"{"usage":1}"#, "c"], to: "p/s.jsonl")
        var lines: [String] = []
        TokenLogs.forEachLine(path: url.path, containing: "\"usage\"") { lines.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(lines, [#"{"usage":1}"#])
    }

    func testFileCacheInvalidatesOnChange() throws {
        let scanner = TokenScanner()
        let path = root.appendingPathComponent("p").path
        let date = now.addingTimeInterval(-60)
        let url = try write([claudeLine("a", at: date)], to: "p/s.jsonl")
        XCTAssertEqual(scan(.claude, roots: [path], scanner: scanner).week, 60)
        XCTAssertEqual(scanner.filesRead, 1)
        XCTAssertEqual(scan(.claude, roots: [path], scanner: scanner).week, 60)
        XCTAssertEqual(scanner.filesRead, 1, "unchanged file is not reread")

        try write([claudeLine("a", at: date), claudeLine("b", at: date)], to: "p/s.jsonl")
        XCTAssertEqual(scan(.claude, roots: [path], scanner: scanner).week, 120)
        XCTAssertEqual(scanner.filesRead, 2, "size changed")

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: url.path)
        _ = scan(.claude, roots: [path], scanner: scanner)
        XCTAssertEqual(scanner.filesRead, 3, "same size, new modification time")

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(scan(.claude, roots: [path], scanner: scanner).isEmpty, "deleted file leaves the cache")
    }

    func testConcurrentScansShareOneQueue() async throws {
        try write([claudeLine("a", at: now.addingTimeInterval(-60))], to: "p/s.jsonl")
        let scanner = TokenScanner()
        let roots: [Provider: [String]] = [.claude: [root.appendingPathComponent("p").path]]
        async let first = scanner.scan(roots: roots, sessionStarts: [:], now: now)
        async let second = scanner.scan(roots: roots, sessionStarts: [:], now: now)
        let results = await [first, second]
        XCTAssertEqual(results[0][.claude], results[1][.claude])
        XCTAssertEqual(scanner.filesRead, 1, "the second scan found the first one's cache")
    }

    func testSessionStartSelection() {
        func window(resetsIn hours: Double, duration: TimeInterval? = 18_000) -> UsageWindow {
            UsageWindow(usedPercent: 1, resetsAt: now.addingTimeInterval(hours * 3600), windowDuration: duration)
        }
        // One account gets exactly its window.
        XCTAssertEqual(TokenLogs.sessionStart(windows: [window(resetsIn: 2)], now: now), now.addingTimeInterval(-3 * 3600))
        // Earliest among active ones; an expired one doesn't count.
        XCTAssertEqual(TokenLogs.sessionStart(windows: [window(resetsIn: 4), window(resetsIn: 1), window(resetsIn: -1)], now: now),
                       now.addingTimeInterval(-4 * 3600))
        // Only expired, no reset or no duration: rolling 5 hours.
        let rolling = now.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(TokenLogs.sessionStart(windows: [window(resetsIn: -1)], now: now), rolling)
        XCTAssertEqual(TokenLogs.sessionStart(windows: [UsageWindow(usedPercent: 1)], now: now), rolling)
        XCTAssertEqual(TokenLogs.sessionStart(windows: [window(resetsIn: 1, duration: nil)], now: now), rolling)
        XCTAssertEqual(TokenLogs.sessionStart(windows: [], now: now), rolling)
    }

    func testFormatTokens() {
        let us = Locale(identifier: "en_US")
        let cases: [(Int, String)] = [
            (0, "0"), (812, "812"), (999, "999"), (1_000, "1.0K"), (3_400, "3.4K"), (9_940, "9.9K"), (9_960, "10K"),
            (10_000, "10K"), (412_000, "412K"), (999_400, "999K"), (999_600, "1.0M"), (3_500_000, "3.5M"),
            (12_800_000, "12.8M"), (99_940_000, "99.9M"), (99_960_000, "100M"), (412_000_000, "412M"), (999_000_000, "999M")
        ]
        for (value, text) in cases {
            XCTAssertEqual(Format.tokens(value, locale: us), text)
            XCTAssertLessThanOrEqual(text.count, 5)
        }
        XCTAssertEqual(Format.tokens(3_500_000, locale: Locale(identifier: "pt_BR")), "3,5M")
        XCTAssertEqual(Format.tokensFull(3_482_110, locale: us), "3,482,110")
        XCTAssertEqual(Format.tokensFull(3_482_110, locale: Locale(identifier: "pt_BR")), "3.482.110")
    }

    func testBarHeights() {
        XCTAssertEqual(TokenLogs.barHeight(0, maximum: 10_000_000), 0)
        XCTAssertEqual(TokenLogs.barHeight(16_000, maximum: 10_000_000), 2, "a small day stays visible")
        XCTAssertEqual(TokenLogs.barHeight(10_000_000, maximum: 10_000_000), 64)
        XCTAssertEqual(TokenLogs.barHeight(5_000_000, maximum: 10_000_000), 32)
    }
}
