import Foundation

public enum RulesEditorError: LocalizedError, Equatable {
    /// The file on disk cannot be parsed, or the edited rules are unusable.
    case invalid(String)
    case changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .changedOnDisk: return "rules.json changed on disk since it was opened"
        }
    }
}

/// Backs the rules window: reads and writes rules.json, and reports what is wrong with a
/// set of rules before they are saved.
public final class RulesEditor {
    public let url: URL
    private var loadedStamp: Date?

    public init(url: URL = Paths.rulesFile) {
        self.url = url
    }

    /// Current rules, creating the file with the defaults if it is missing. A parse failure
    /// arrives as `.invalid` with the location, e.g. `missing "destination" at rules[3]`.
    public func load() throws -> Config {
        do {
            let config = try ConfigStore.loadOrCreate(at: url)
            loadedStamp = FileStat.modified(of: url)
            return config
        } catch let error as DecodingError {
            loadedStamp = FileStat.modified(of: url)
            throw RulesEditorError.invalid(ConfigStore.describe(error))
        }
    }

    /// True when something else wrote the file after the editor last read or saved it.
    public var changedOnDisk: Bool {
        loadedStamp != FileStat.modified(of: url)
    }

    /// Refuses rules that cannot work, and refuses to clobber an outside edit unless forced.
    public func save(_ config: Config, force: Bool = false) throws {
        let problems = Self.problems(in: config)
        guard problems.isEmpty else {
            throw RulesEditorError.invalid(problems.joined(separator: "; "))
        }
        if !force, changedOnDisk { throw RulesEditorError.changedOnDisk }
        try ConfigStore.save(config, to: url)
        loadedStamp = FileStat.modified(of: url)
    }

    /// Blocking: saving in this state would write a rule that can never run.
    public static func problems(in config: Config) -> [String] {
        var problems: [String] = []
        if config.settleSeconds < 0 {
            problems.append("Settle seconds cannot be negative")
        }
        for (index, rule) in config.rules.enumerated() {
            let label = rule.name.isEmpty ? "Rule \(index + 1)" : rule.name
            if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Rule \(index + 1) needs a name")
            }
            if rule.watch.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                problems.append("\(label) needs at least one folder to watch")
            }
            if rule.destination.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(label) needs a destination")
            }
        }
        return problems
    }

    /// Non-blocking: the rules save, but something in them will not do what it looks like.
    public static func warnings(in config: Config) -> [String] {
        RuleMatcher(config: config).warnings()
    }
}
