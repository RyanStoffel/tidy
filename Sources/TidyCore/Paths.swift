import Foundation

/// Filesystem locations Tidy owns, plus tilde expansion shared by the rules engine.
public enum Paths {
    public static let appName = "Tidy"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var rulesFile: URL {
        supportDirectory.appendingPathComponent("rules.json", isDirectory: false)
    }

    public static var logFile: URL {
        supportDirectory.appendingPathComponent("log.json", isDirectory: false)
    }

    /// Expands a leading `~` and normalizes the result. Does not require the path to exist.
    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Replaces the home directory prefix with `~` for display.
    public static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Comparable form of a directory path: symlinks resolved so /var and /private/var agree.
    public static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
