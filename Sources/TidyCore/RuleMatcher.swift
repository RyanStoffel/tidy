import Foundation

/// The filesystem facts a rule needs. Read once per candidate so matching stays pure.
public struct FileFacts {
    public let url: URL
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let size: Int64
    public let modified: Date
    public let accessed: Date

    public init(
        url: URL,
        isDirectory: Bool,
        isSymlink: Bool,
        isHidden: Bool,
        size: Int64,
        modified: Date,
        accessed: Date
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.accessed = accessed
    }

    public static func read(_ url: URL) -> FileFacts? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return FileFacts(
            url: url,
            isDirectory: values.isDirectory ?? false,
            isSymlink: values.isSymbolicLink ?? false,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            accessed: values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
        )
    }
}

public struct MatchResult: Equatable {
    public let rule: Rule
    /// Directory the file should end up in. Collision handling happens later.
    public let destinationDirectory: URL
}

/// Decides which rule claims a file and where it should go. Pure: no filesystem writes,
/// no stat calls beyond what the caller already gathered.
public struct RuleMatcher {
    /// Tokens usable in `destination` in addition to a pattern's named capture groups.
    public static let knownTokens: Set<String> = [
        "term", "sourceFolder", "ext", "name", "stem", "course", "fileYear", "fileMonth", "fileDay",
    ]

    public let config: Config
    private let patterns: [NSRegularExpression?]
    private let patternGroups: [[String]]
    private let watchSets: [Set<String>]
    private let extensionSets: [Set<String>?]
    /// Course codes as written in the config, paired with their normalized form,
    /// longest first so CS101 wins over CS10.
    private let courseCodes: [(canonical: String, normalized: String)]

    public init(config: Config) {
        self.config = config
        patterns = config.rules.map { rule in
            guard let pattern = rule.match.namePattern else { return nil }
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        patternGroups = config.rules.map { Self.groupNames(in: $0.match.namePattern) }
        watchSets = config.rules.map { Set($0.watch.map { Paths.canonical(Paths.expand($0)) }) }
        extensionSets = config.rules.map { rule in
            guard let exts = rule.match.extensions, !exts.isEmpty else { return nil }
            return Set(exts.map { $0.lowercased() })
        }
        courseCodes = config.courseCodes
            .map { (canonical: $0, normalized: Self.normalize($0)) }
            .filter { !$0.normalized.isEmpty }
            .sorted { $0.normalized.count > $1.normalized.count }
    }

    /// First enabled rule whose trigger is active, whose watch list contains the file's
    /// parent, and whose conditions all hold.
    public func match(_ facts: FileFacts, triggers: Set<Rule.Trigger>, now: Date = Date()) -> MatchResult? {
        let parent = Paths.canonical(facts.url.deletingLastPathComponent())
        let filename = facts.url.lastPathComponent

        for (index, rule) in config.rules.enumerated() {
            guard rule.enabled, triggers.contains(rule.trigger) else { continue }
            guard watchSets[index].contains(parent) else { continue }
            guard !facts.isDirectory || rule.includeDirectories else { continue }

            if let exts = extensionSets[index] {
                guard exts.contains(facts.url.pathExtension.lowercased()) else { continue }
            }

            var captures: [String: String] = [:]
            if rule.match.namePattern != nil {
                guard let regex = patterns[index],
                      let match = regex.firstMatch(
                          in: filename,
                          options: [.anchored],
                          range: NSRange(filename.startIndex..., in: filename)
                      ),
                      match.range.length == filename.utf16.count
                else { continue }
                captures = Self.captures(named: patternGroups[index], from: match, in: filename)
            }

            if let days = rule.match.minAgeDays {
                guard Self.age(of: facts.modified, at: now) >= Double(days) else { continue }
            }
            if let days = rule.match.minIdleDays {
                let idle = min(Self.age(of: facts.modified, at: now), Self.age(of: facts.accessed, at: now))
                guard idle >= Double(days) else { continue }
            }

            var course: String?
            if rule.match.requiresCourseCode {
                guard let found = courseCode(in: filename) else { continue }
                course = found
            }

            guard let destination = destination(for: rule, facts: facts, captures: captures, course: course)
            else { continue }
            return MatchResult(rule: rule, destinationDirectory: destination)
        }
        return nil
    }

    /// Course code found in a filename, returned in the spelling used in the config
    /// so the destination folder name stays stable.
    public func courseCode(in filename: String) -> String? {
        let normalized = Array(Self.normalize(filename))
        guard !normalized.isEmpty else { return nil }
        for code in courseCodes {
            let needle = Array(code.normalized)
            guard needle.count <= normalized.count else { continue }
            for start in 0...(normalized.count - needle.count) {
                guard Array(normalized[start..<(start + needle.count)]) == needle else { continue }
                // Reject CS10 inside CS101: a digit may not follow the code.
                let after = start + needle.count
                if after < normalized.count, normalized[after].isNumber { continue }
                return code.canonical
            }
        }
        return nil
    }

    /// Static problems worth surfacing before a rule silently never fires.
    public func warnings() -> [String] {
        var warnings: [String] = []
        for (index, rule) in config.rules.enumerated() {
            if let pattern = rule.match.namePattern, patterns[index] == nil {
                warnings.append("\(rule.name): namePattern is not a valid regex: \(pattern)")
            }
            if rule.watch.isEmpty {
                warnings.append("\(rule.name): watch list is empty")
            }
            if rule.match.requiresCourseCode, courseCodes.isEmpty {
                warnings.append("\(rule.name): requiresCourseCode is set but courseCodes is empty")
            }
            let allowed = Self.knownTokens.union(patternGroups[index])
            for token in Self.tokens(in: rule.destination) where !allowed.contains(token) {
                warnings.append("\(rule.name): destination uses unknown token {\(token)}")
            }
        }
        return warnings
    }

    // MARK: - Destination

    private func destination(
        for rule: Rule,
        facts: FileFacts,
        captures: [String: String],
        course: String?
    ) -> URL? {
        var values = captures
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: facts.modified)
        values["term"] = config.courseTerm
        values["sourceFolder"] = facts.url.deletingLastPathComponent().lastPathComponent
        values["ext"] = facts.url.pathExtension.lowercased()
        values["name"] = facts.url.lastPathComponent
        values["stem"] = facts.url.deletingPathExtension().lastPathComponent
        values["fileYear"] = String(format: "%04d", parts.year ?? 0)
        values["fileMonth"] = String(format: "%02d", parts.month ?? 0)
        values["fileDay"] = String(format: "%02d", parts.day ?? 0)
        if let course { values["course"] = course }

        guard let resolved = Self.substitute(rule.destination, values: values) else { return nil }
        let directory = Paths.expand(resolved)

        // A rule that would move a file onto itself, or a directory inside itself, is a no-op.
        let parent = Paths.canonical(facts.url.deletingLastPathComponent())
        let target = Paths.canonical(directory)
        if target == parent { return nil }
        if facts.isDirectory, target == Paths.canonical(facts.url) || target.hasPrefix(Paths.canonical(facts.url) + "/") {
            return nil
        }
        return directory
    }

    /// Replaces `{token}`. Returns nil when a token has no value, so the rule is skipped
    /// instead of creating a folder literally named `{course}`.
    static func substitute(_ template: String, values: [String: String]) -> String? {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            let token = String(rest[rest.index(after: open)..<close])
            guard let value = values[token], !value.isEmpty else { return nil }
            result += Self.sanitize(value)
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// Token values become one path component, so separators are not allowed through.
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    static func tokens(in template: String) -> [String] {
        var found: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    // MARK: - Helpers

    private static func age(of date: Date, at now: Date) -> Double {
        now.timeIntervalSince(date) / 86_400
    }

    static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// NSRegularExpression cannot list its group names, so read them off the pattern.
    private static func groupNames(in pattern: String?) -> [String] {
        guard let pattern,
              let finder = try? NSRegularExpression(pattern: #"\(\?<([A-Za-z_][A-Za-z0-9_]*)>"#)
        else { return [] }
        let range = NSRange(pattern.startIndex..., in: pattern)
        return finder.matches(in: pattern, range: range).compactMap { match in
            Range(match.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }

    private static func captures(
        named names: [String],
        from match: NSTextCheckingResult,
        in subject: String
    ) -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            guard let range = Range(match.range(withName: name), in: subject) else { continue }
            values[name] = String(subject[range])
        }
        return values
    }
}
