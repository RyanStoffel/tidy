import Foundation

/// One organizing rule. Rules are evaluated in file order and the first match wins,
/// so put specific rules above catch-alls.
public struct Rule: Codable, Equatable {
    /// When a rule is considered. `event` rules also run during the daily sweep;
    /// `daily` rules only run on the timer, which is what age-based rules want.
    public enum Trigger: String, Codable {
        case event
        case daily
    }

    public var name: String
    public var enabled: Bool
    public var trigger: Trigger
    /// Directories watched by this rule. Only their direct children are considered.
    public var watch: [String]
    public var match: Match
    /// Destination directory, with `{token}` substitution. See RuleMatcher.knownTokens.
    public var destination: String
    /// Directories are ignored unless this is true.
    public var includeDirectories: Bool

    public init(
        name: String,
        enabled: Bool = true,
        trigger: Trigger = .event,
        watch: [String],
        match: Match = Match(),
        destination: String,
        includeDirectories: Bool = false
    ) {
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.watch = watch
        self.match = match
        self.destination = destination
        self.includeDirectories = includeDirectories
    }

    private enum CodingKeys: String, CodingKey {
        case name, enabled, trigger, watch, match, destination, includeDirectories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .event
        watch = try c.decode([String].self, forKey: .watch)
        match = try c.decodeIfPresent(Match.self, forKey: .match) ?? Match()
        destination = try c.decode(String.self, forKey: .destination)
        includeDirectories = try c.decodeIfPresent(Bool.self, forKey: .includeDirectories) ?? false
    }
}

/// Conditions a file must meet. Omitted conditions are not checked, so an empty
/// `Match` accepts every file in the watched directories.
public struct Match: Codable, Equatable {
    /// Case-insensitive regex matched against the whole filename. Named groups
    /// such as `(?<year>\d{4})` become `{year}` tokens in the destination.
    public var namePattern: String?
    /// Extensions without the dot, compared case-insensitively.
    public var extensions: [String]?
    /// Matches when the modification date is at least this many days old.
    public var minAgeDays: Int?
    /// Matches when both the modification and access dates are at least this many days old.
    public var minIdleDays: Int?
    /// Requires one of `courseCodes` in the filename; the match becomes `{course}`.
    public var requiresCourseCode: Bool

    public init(
        namePattern: String? = nil,
        extensions: [String]? = nil,
        minAgeDays: Int? = nil,
        minIdleDays: Int? = nil,
        requiresCourseCode: Bool = false
    ) {
        self.namePattern = namePattern
        self.extensions = extensions
        self.minAgeDays = minAgeDays
        self.minIdleDays = minIdleDays
        self.requiresCourseCode = requiresCourseCode
    }

    private enum CodingKeys: String, CodingKey {
        case namePattern, extensions, minAgeDays, minIdleDays, requiresCourseCode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namePattern = try c.decodeIfPresent(String.self, forKey: .namePattern)
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        minIdleDays = try c.decodeIfPresent(Int.self, forKey: .minIdleDays)
        requiresCourseCode = try c.decodeIfPresent(Bool.self, forKey: .requiresCourseCode) ?? false
    }
}

/// Everything Tidy reads from `~/Library/Application Support/Tidy/rules.json`.
public struct Config: Codable, Equatable {
    public var schemaVersion: Int
    /// Gap between the two size samples that decide a file finished being written.
    public var settleSeconds: Double
    /// Substituted as `{term}`; bump this each semester.
    public var courseTerm: String
    /// Recognized course codes, matched ignoring case, spaces and dashes.
    public var courseCodes: [String]
    /// Extensions that mean "still downloading". Never touched.
    public var skipExtensions: [String]
    /// Processes allowed to hold a file open without blocking a move.
    public var ignoreProcesses: [String]
    public var rules: [Rule]

    public init(
        schemaVersion: Int = 1,
        settleSeconds: Double = 5,
        courseTerm: String = "FA26",
        courseCodes: [String] = [],
        skipExtensions: [String] = Config.defaultSkipExtensions,
        ignoreProcesses: [String] = Config.defaultIgnoreProcesses,
        rules: [Rule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settleSeconds = settleSeconds
        self.courseTerm = courseTerm
        self.courseCodes = courseCodes
        self.skipExtensions = skipExtensions
        self.ignoreProcesses = ignoreProcesses
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settleSeconds, courseTerm, courseCodes, skipExtensions, ignoreProcesses, rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? 5
        courseTerm = try c.decodeIfPresent(String.self, forKey: .courseTerm) ?? "FA26"
        courseCodes = try c.decodeIfPresent([String].self, forKey: .courseCodes) ?? []
        skipExtensions = try c.decodeIfPresent([String].self, forKey: .skipExtensions) ?? Config.defaultSkipExtensions
        ignoreProcesses = try c.decodeIfPresent([String].self, forKey: .ignoreProcesses) ?? Config.defaultIgnoreProcesses
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    public static let defaultSkipExtensions = [
        "crdownload", "download", "part", "partial", "opdownload", "aria2", "filepart", "tmp",
    ]

    /// Spotlight, Quick Look and Time Machine touch files constantly; they must not
    /// count as "open by another process".
    public static let defaultIgnoreProcesses = [
        "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport",
        "fseventsd", "backupd", "Spotlight", "QuickLookSatellite", "quicklookd", "Tidy",
    ]
}

// MARK: - Load / save

public enum ConfigStore {
    /// Loads the config, writing the default file first if none exists.
    public static func loadOrCreate(at url: URL = Paths.rulesFile) throws -> Config {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Paths.ensureSupportDirectory()
            try save(.default, to: url)
            return .default
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public static func save(_ config: Config, to url: URL = Paths.rulesFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Defaults

extension Config {
    /// Written to rules.json on first launch. Mirrored by rules.json in the repo.
    public static let `default` = Config(
        courseCodes: ["CS101", "CS475", "MATH-241", "ENGR 310"],
        rules: [
            Rule(
                name: "Screenshots",
                watch: ["~/Desktop"],
                match: Match(
                    namePattern: #"^Screen ?shot (?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2}) at .+\.png$"#
                ),
                destination: "~/Pictures/Screenshots/{year}/{month}"
            ),
            Rule(
                name: "School documents",
                watch: ["~/Downloads/Documents"],
                match: Match(extensions: ["pdf", "doc", "docx"], requiresCourseCode: true),
                destination: "~/Documents/School/{term}/Courses/{course}"
            ),
            Rule(
                name: "Downloads: code",
                watch: ["~/Downloads"],
                match: Match(extensions: [
                    "py", "js", "ts", "tsx", "jsx", "json", "sh", "zsh", "bash", "ipynb",
                    "swift", "rs", "go", "c", "h", "cpp", "hpp", "java", "rb", "sql",
                    "yaml", "yml", "toml", "patch", "diff",
                ]),
                destination: "~/Downloads/Code"
            ),
            Rule(
                name: "Downloads: images",
                watch: ["~/Downloads"],
                match: Match(extensions: [
                    "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff", "bmp",
                ]),
                destination: "~/Downloads/Images"
            ),
            Rule(
                name: "Downloads: videos",
                watch: ["~/Downloads"],
                match: Match(extensions: ["mp4", "mov", "avi", "mkv", "webm", "m4v"]),
                destination: "~/Downloads/Videos"
            ),
            Rule(
                name: "Downloads: documents",
                watch: ["~/Downloads"],
                match: Match(extensions: [
                    "pdf", "docx", "doc", "pptx", "ppt", "xlsx", "xls", "txt", "md",
                    "rtf", "csv", "epub", "pages", "numbers", "key",
                ]),
                destination: "~/Downloads/Documents"
            ),
            Rule(
                name: "Downloads: everything else",
                watch: ["~/Downloads"],
                destination: "~/Downloads/Random"
            ),
            Rule(
                name: "Archive stale downloads",
                trigger: .daily,
                watch: [
                    "~/Downloads/Code",
                    "~/Downloads/Images",
                    "~/Downloads/Videos",
                    "~/Downloads/Documents",
                    "~/Downloads/Random",
                ],
                match: Match(minIdleDays: 30),
                destination: "~/Downloads/Archive/{sourceFolder}"
            ),
        ]
    )
}
