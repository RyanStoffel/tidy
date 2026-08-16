import Foundation

/// Applies the rules: scans watched directories, decides, and moves.
/// All calls are expected to happen on one serial queue.
public final class Organizer {
    public struct Outcome {
        public enum Kind: Equatable {
            case moved
            case dryRun
            case failed
            /// Matched a rule but a guard held it back; not worth logging to the move log.
            case skipped
        }

        public let rule: String
        public let source: URL
        public let destination: URL?
        public let kind: Kind
        public let detail: String?

        public var summary: String {
            switch kind {
            case .moved: return "moved \(Paths.abbreviate(source)) -> \(destination.map(Paths.abbreviate) ?? "?")"
            case .dryRun: return "would move \(Paths.abbreviate(source)) -> \(destination.map(Paths.abbreviate) ?? "?")"
            case .failed: return "failed \(Paths.abbreviate(source)): \(detail ?? "unknown error")"
            case .skipped: return "skipped \(Paths.abbreviate(source)): \(detail ?? "guard")"
            }
        }

        /// Skips are deliberately not logged; they repeat on every sweep.
        public var logEntry: LogEntry? {
            let logKind: LogEntry.Kind
            switch kind {
            case .moved: logKind = .moved
            case .dryRun: logKind = .dryRun
            case .failed: logKind = .failed
            case .skipped: return nil
            }
            return LogEntry(
                rule: rule,
                source: Paths.abbreviate(source),
                destination: destination.map(Paths.abbreviate),
                kind: logKind,
                detail: detail
            )
        }
    }

    public let config: Config
    /// When true, everything is evaluated and reported but no file is touched.
    public var dryRun: Bool

    private let matcher: RuleMatcher
    private let guards: FileGuards
    private let fileManager: FileManager

    public init(config: Config, dryRun: Bool, fileManager: FileManager = .default) {
        self.config = config
        self.dryRun = dryRun
        self.fileManager = fileManager
        matcher = RuleMatcher(config: config)
        guards = FileGuards(config: config, fileManager: fileManager)
    }

    public func warnings() -> [String] { matcher.warnings() }

    /// Deduplicated watch directories for the given triggers, in rule order.
    public func directories(for triggers: Set<Rule.Trigger>) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for rule in config.rules where rule.enabled && triggers.contains(rule.trigger) {
            for path in rule.watch {
                let url = Paths.expand(path)
                if seen.insert(Paths.canonical(url)).inserted { result.append(url) }
            }
        }
        return result
    }

    public func sweep(triggers: Set<Rule.Trigger>, now: Date = Date()) -> [Outcome] {
        directories(for: triggers).flatMap { process(directory: $0, triggers: triggers, now: now) }
    }

    public func process(directory: URL, triggers: Set<Rule.Trigger>, now: Date = Date()) -> [Outcome] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            return [Outcome(
                rule: "-",
                source: directory,
                destination: nil,
                kind: .failed,
                detail: "cannot read directory: \(error.localizedDescription)"
            )]
        }
        return contents.sorted { $0.path < $1.path }.compactMap {
            process(file: $0, triggers: triggers, now: now)
        }
    }

    /// nil when no rule claims the file.
    public func process(file url: URL, triggers: Set<Rule.Trigger>, now: Date = Date()) -> Outcome? {
        guard let facts = FileFacts.read(url) else { return nil }
        if let reason = guards.staticSkipReason(for: facts) {
            // Only report a guard hit if some rule actually wanted the file.
            guard matcher.match(facts, triggers: triggers, now: now) != nil else { return nil }
            return Outcome(rule: "-", source: url, destination: nil, kind: .skipped, detail: reason.description)
        }
        guard let result = matcher.match(facts, triggers: triggers, now: now) else { return nil }

        if let reason = guards.liveSkipReason(for: facts, waitForSettle: !dryRun) {
            return Outcome(
                rule: result.rule.name,
                source: url,
                destination: result.destinationDirectory,
                kind: .skipped,
                detail: reason.description
            )
        }

        // A slow settle window means the file may be gone or renamed by now.
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let target = Self.uniqueDestination(
            for: url.lastPathComponent,
            in: result.destinationDirectory,
            fileManager: fileManager
        )
        if dryRun {
            return Outcome(rule: result.rule.name, source: url, destination: target, kind: .dryRun, detail: nil)
        }
        do {
            try fileManager.createDirectory(at: result.destinationDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: target)
            return Outcome(rule: result.rule.name, source: url, destination: target, kind: .moved, detail: nil)
        } catch {
            return Outcome(
                rule: result.rule.name,
                source: url,
                destination: target,
                kind: .failed,
                detail: error.localizedDescription
            )
        }
    }

    /// Never overwrite: `report.pdf` becomes `report (1).pdf`, then `report (2).pdf`.
    public static func uniqueDestination(
        for filename: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let name = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 1
        while true {
            var attempt = "\(name) (\(counter))"
            if !ext.isEmpty { attempt += ".\(ext)" }
            let url = directory.appendingPathComponent(attempt)
            if !fileManager.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }
}
