import Foundation

/// One row of the rule list shown above the editor. `id` is the evaluation position,
/// which is what makes first-match-wins readable while editing.
public struct RuleSummary: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let trigger: String
    public let watch: String
    public let destination: String
    public let enabled: Bool
}

/// Validation state of the text currently in the editor.
public struct RulesSnapshot: Equatable {
    public let text: String
    /// nil when the text parses.
    public let error: String?
    public let warnings: [String]
    public let summary: [RuleSummary]

    public var isValid: Bool { error == nil }
    public var ruleCount: Int { summary.count }

    /// Placeholder for a window that has not read the file yet.
    public static let empty = RulesSnapshot(text: "", error: nil, warnings: [], summary: [])
}

public enum RulesEditorError: LocalizedError, Equatable {
    case invalid(String)
    case changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .changedOnDisk: return "rules.json changed on disk since it was opened"
        }
    }
}

/// Backs the rules editor window: reads the file, validates text without touching disk,
/// and saves only text that parses.
public final class RulesEditor {
    public let url: URL
    private var loadedStamp: Date?

    public init(url: URL = Paths.rulesFile) {
        self.url = url
    }

    /// Current file contents, creating the file with the defaults if it is missing.
    public func load() throws -> RulesSnapshot {
        _ = try ConfigStore.loadOrCreate(at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        loadedStamp = Self.stamp(of: url)
        return inspect(text)
    }

    /// Pure: no reads, no writes. Safe to call on every keystroke.
    public func inspect(_ text: String) -> RulesSnapshot {
        do {
            let config = try ConfigStore.decode(text)
            return RulesSnapshot(
                text: text,
                error: nil,
                warnings: RuleMatcher(config: config).warnings(),
                summary: Self.summarize(config)
            )
        } catch {
            return RulesSnapshot(text: text, error: ConfigStore.describe(error), warnings: [], summary: [])
        }
    }

    /// True when something else wrote the file after the editor last read it.
    public var changedOnDisk: Bool {
        loadedStamp != Self.stamp(of: url)
    }

    /// Saves the text verbatim. Refuses text that does not parse, and refuses to clobber
    /// an outside edit unless forced.
    public func save(_ text: String, force: Bool = false) throws {
        let snapshot = inspect(text)
        guard let error = snapshot.error else {
            if !force, changedOnDisk { throw RulesEditorError.changedOnDisk }
            try ConfigStore.write(text, to: url)
            loadedStamp = Self.stamp(of: url)
            return
        }
        throw RulesEditorError.invalid(error)
    }

    private static func summarize(_ config: Config) -> [RuleSummary] {
        config.rules.enumerated().map { index, rule in
            RuleSummary(
                id: index + 1,
                name: rule.name,
                trigger: rule.trigger.rawValue,
                watch: rule.watch.joined(separator: ", "),
                destination: rule.destination,
                enabled: rule.enabled
            )
        }
    }

    private static func stamp(of url: URL) -> Date? {
        FileStat.modified(of: url)
    }
}
