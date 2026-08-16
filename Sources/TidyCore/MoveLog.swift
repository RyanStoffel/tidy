import Foundation

public struct LogEntry: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable {
        case moved
        case dryRun
        case failed
    }

    public let id: UUID
    public let date: Date
    public let rule: String
    public let source: String
    public let destination: String?
    public let kind: Kind
    public let detail: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        rule: String,
        source: String,
        destination: String?,
        kind: Kind,
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.rule = rule
        self.source = source
        self.destination = destination
        self.kind = kind
        self.detail = detail
    }
}

/// Rolling JSON log of everything Tidy did, newest first, capped so it never grows.
public final class MoveLog {
    public static let defaultLimit = 500

    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    private var entries: [LogEntry]

    public init(url: URL = Paths.logFile, limit: Int = MoveLog.defaultLimit) {
        self.url = url
        self.limit = limit
        entries = Self.read(from: url)
    }

    public func append(_ newEntries: [LogEntry]) {
        guard !newEntries.isEmpty else { return }
        lock.lock()
        entries = (newEntries.reversed() + entries).prefix(limit).map { $0 }
        let snapshot = entries
        lock.unlock()
        write(snapshot)
    }

    /// Newest first.
    public func recent(_ count: Int? = nil) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let count else { return entries }
        return Array(entries.prefix(count))
    }

    public func clear() {
        lock.lock()
        entries = []
        lock.unlock()
        write([])
    }

    public var fileURL: URL { url }

    private func write(_ snapshot: [LogEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func read(from url: URL) -> [LogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LogEntry].self, from: data)) ?? []
    }
}
