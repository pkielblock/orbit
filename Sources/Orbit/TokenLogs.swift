import Foundation

/// Tokens from one log line. Only ids, timestamps and counts are read; message content is never kept.
struct TokenEvent: Equatable {
    let date: Date
    let tokens: Int
    /// Claude's message and request ids. The same message repeats across lines and files.
    var key: String?
}

struct TokenDay: Identifiable, Equatable {
    let day: Date
    var tokens: Int
    var id: Date { day }
}

/// One provider's tokens across all its accounts: logs have no account identity.
struct ProviderTokens: Equatable {
    var session: Int
    /// Oldest first; the last is today.
    var days: [TokenDay]
    var week: Int { days.reduce(0) { $0 + $1.tokens } }
    var isEmpty: Bool { week == 0 && session == 0 }
}

enum TokenLogs {
    static let rollingSession: TimeInterval = 5 * 3600

    /// The earliest start among active windows, so one account gets exactly its window. Rolling 5 hours when none is active.
    static func sessionStart(windows: [UsageWindow], now: Date) -> Date {
        windows.compactMap { window -> Date? in
            guard let reset = window.resetsAt, let duration = window.windowDuration, reset > now else { return nil }
            return reset.addingTimeInterval(-duration)
        }.min() ?? now.addingTimeInterval(-rollingSession)
    }

    /// Today and the previous 6 local days, oldest first. Calendar arithmetic, so DST days keep their real start.
    static func dayStarts(now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today) ?? today }
    }

    static func totals(_ events: [TokenEvent], sessionStart: Date, now: Date, calendar: Calendar = .current) -> ProviderTokens {
        var unique: [String: TokenEvent] = [:]
        var counted: [TokenEvent] = []
        for event in events {
            guard let key = event.key else { counted.append(event); continue }
            if let other = unique[key] {
                // Earliest time and largest count, so the result doesn't depend on file order.
                unique[key] = TokenEvent(date: min(other.date, event.date), tokens: max(other.tokens, event.tokens), key: key)
            } else {
                unique[key] = event
            }
        }
        var days = dayStarts(now: now, calendar: calendar).map { TokenDay(day: $0, tokens: 0) }
        var session = 0
        for event in counted + unique.values where event.date <= now {
            if event.date >= sessionStart { session += event.tokens }
            let day = calendar.startOfDay(for: event.date)
            if let index = days.firstIndex(where: { $0.day == day }) { days[index].tokens += event.tokens }
        }
        return ProviderTokens(session: session, days: days)
    }

    /// Bar height in a 64 pt chart: linear, with non-zero days always visible.
    static func barHeight(_ value: Int, maximum: Int, full: CGFloat = 64) -> CGFloat {
        guard value > 0, maximum > 0 else { return 0 }
        return max(2, full * CGFloat(value) / CGFloat(maximum))
    }

    /// Clamped so a corrupt log can't overflow the sums.
    private static func count(_ value: Any?) -> Int {
        min(max((value as? NSNumber)?.intValue ?? 0, 0), 1 << 40)
    }

    /// Input + output + cache writes; cache reads don't count.
    static func claudeEvent(_ line: Data) -> TokenEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String, let request = root["requestId"] as? String,
              let date = Dates.parse(root["timestamp"]) else { return nil }
        let tokens = count(usage["input_tokens"]) + count(usage["output_tokens"]) + count(usage["cache_creation_input_tokens"])
        return TokenEvent(date: date, tokens: tokens, key: "\(id)|\(request)")
    }

    static func claudeEvents(path: String) -> [TokenEvent] {
        var events: [TokenEvent] = []
        forEachLine(path: path, containing: "\"usage\"") { line in
            if let event = claudeEvent(line) { events.append(event) }
        }
        return events
    }

    /// Codex totals are cumulative per file and events repeat, so only positive deltas of uncached tokens count.
    /// A dropped total becomes the new baseline without being counted.
    /// shortcut: a forked session replaying its parent's history starts high and counts that history again, upgrade if Codex logs expose the fork's starting total.
    static func codexEvents(path: String) -> [TokenEvent] {
        var events: [TokenEvent] = []
        var last = 0
        forEachLine(path: path, containing: "\"token_count\"") { line in
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any], usage["total_tokens"] is NSNumber,
                  let date = Dates.parse(root["timestamp"]) else { return }
            let total = max(count(usage["total_tokens"]) - count(usage["cached_input_tokens"]), 0)
            if total > last { events.append(TokenEvent(date: date, tokens: total - last)) }
            last = total
        }
        return events
    }

    /// Streams a file in chunks and hands over only lines holding `marker`, so most of a log never reaches the JSON parser.
    static func forEachLine(path: String, containing marker: String, _ body: (Data) -> Void) {
        guard let file = fopen(path, "r") else { return }
        defer { fclose(file) }
        let needle = Array(marker.utf8)
        let chunkSize = 1 << 20
        let longestLine = 64 << 20 // anything longer is skipped, like any other malformed line
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var partial = Data()
        var skipping = false

        func deliver(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress, memmem(base, bytes.count, needle, needle.count) != nil else { return }
            body(Data(bytes))
        }

        while true {
            let read = fread(&chunk, 1, chunkSize, file)
            guard read > 0 else { break }
            chunk.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                var start = 0
                while start < read, let hit = memchr(base + start, 10, read - start) {
                    let end = base.distance(to: UnsafeRawPointer(hit))
                    let piece = UnsafeRawBufferPointer(start: base + start, count: end - start)
                    if skipping {
                        skipping = false
                    } else if partial.isEmpty {
                        deliver(piece)
                    } else {
                        partial.append(contentsOf: piece)
                        partial.withUnsafeBytes(deliver)
                    }
                    partial.removeAll(keepingCapacity: true)
                    start = end + 1
                }
                if start < read, !skipping {
                    partial.append(contentsOf: UnsafeRawBufferPointer(start: base + start, count: read - start))
                    if partial.count > longestLine {
                        partial = Data()
                        skipping = true
                    }
                }
            }
        }
        if !partial.isEmpty { partial.withUnsafeBytes(deliver) }
    }
}

/// Reads provider logs off the main actor and keeps parsed events per file, so a refresh rereads only what changed.
final class TokenScanner: @unchecked Sendable {
    private struct CachedFile {
        let size: Int
        let modified: Date
        let events: [TokenEvent]
    }

    // The serial queue owns the cache and runs one scan at a time, on its own thread rather than the concurrency pool quota refreshes use.
    private let queue = DispatchQueue(label: "orbit.token-scan", qos: .utility)
    private var cache: [String: CachedFile] = [:]
    private(set) var filesRead = 0

    func scan(roots: [Provider: [String]], sessionStarts: [Provider: Date], now: Date = Date()) async -> [Provider: ProviderTokens] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.scanNow(roots: roots, sessionStarts: sessionStarts, now: now)) }
        }
    }

    func scanNow(roots: [Provider: [String]], sessionStarts: [Provider: Date], now: Date = Date(), calendar: Calendar = .current) -> [Provider: ProviderTokens] {
        let cutoff = TokenLogs.dayStarts(now: now, calendar: calendar)[0]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var live = Set<String>()
        var result: [Provider: ProviderTokens] = [:]
        for (provider, providerRoots) in roots {
            var events: [TokenEvent] = []
            // Enumeration doesn't follow symlinks, and two accounts may share one real folder: resolve, then scan each once.
            for root in Set(providerRoots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) {
                guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                                 options: [], errorHandler: { _, _ in true }) else { continue }
                for case let url as URL in files where url.pathExtension == "jsonl" {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                          let size = values.fileSize, let modified = values.contentModificationDate, modified >= cutoff,
                          live.insert(url.path).inserted else { continue }
                    if let cached = cache[url.path], cached.size == size, cached.modified == modified {
                        events += cached.events
                        continue
                    }
                    filesRead += 1
                    let parsed = autoreleasepool {
                        provider == .claude ? TokenLogs.claudeEvents(path: url.path) : TokenLogs.codexEvents(path: url.path)
                    }
                    cache[url.path] = CachedFile(size: size, modified: modified, events: parsed)
                    events += parsed
                }
            }
            let start = sessionStarts[provider] ?? now.addingTimeInterval(-TokenLogs.rollingSession)
            result[provider] = TokenLogs.totals(events, sessionStart: start, now: now, calendar: calendar)
        }
        cache = cache.filter { live.contains($0.key) }
        return result
    }
}
