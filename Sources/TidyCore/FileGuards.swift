import Foundation

/// Safety checks that keep Tidy away from files it must not touch, and hold it back
/// until a file has finished being written.
public final class FileGuards {
    public enum SkipReason: Equatable {
        case hidden
        case symlink
        case inProgressDownload(String)
        case obsidianVault
        case versionControl
        case unstable
        case openByAnotherProcess(String)

        public var description: String {
            switch self {
            case .hidden: return "hidden file"
            case .symlink: return "symlink or alias"
            case .inProgressDownload(let ext): return "still downloading (.\(ext))"
            case .obsidianVault: return "inside an Obsidian vault"
            case .versionControl: return "inside a version control directory"
            case .unstable: return "size still changing"
            case .openByAnotherProcess(let name): return "open in \(name)"
            }
        }
    }

    private let skipExtensions: Set<String>
    private let ignoreProcesses: Set<String>
    private let settleSeconds: Double
    private let fileManager: FileManager
    /// Obsidian vault lookups walk ancestors, so results are cached per directory.
    private var vaultCache: [String: Bool] = [:]

    public init(config: Config, fileManager: FileManager = .default) {
        skipExtensions = Set(config.skipExtensions.map { $0.lowercased() })
        ignoreProcesses = Set(config.ignoreProcesses)
        settleSeconds = config.settleSeconds
        self.fileManager = fileManager
    }

    /// Checks that need no waiting. Run before a rule is allowed to claim a file.
    public func staticSkipReason(for facts: FileFacts) -> SkipReason? {
        let name = facts.url.lastPathComponent
        if facts.isSymlink { return .symlink }
        if name.hasPrefix(".") || facts.isHidden { return .hidden }
        let ext = facts.url.pathExtension.lowercased()
        if skipExtensions.contains(ext) { return .inProgressDownload(ext) }
        if name == ".git" || name == ".svn" { return .versionControl }
        for component in facts.url.pathComponents.dropLast() where component == ".git" || component == ".svn" {
            return .versionControl
        }
        if isInsideObsidianVault(facts.url) { return .obsidianVault }
        return nil
    }

    /// Checks that cost time or a subprocess. Run only once a rule has claimed the file.
    /// `waitForSettle` is false in dry-run mode, where nothing is moved anyway.
    public func liveSkipReason(for facts: FileFacts, waitForSettle: Bool) -> SkipReason? {
        if waitForSettle, !isStable(facts.url, initialSize: facts.size) { return .unstable }
        if let holder = openingProcess(facts.url) { return .openByAnotherProcess(holder) }
        return nil
    }

    /// Samples the size twice, `settleSeconds` apart, and reports whether it held still.
    public func isStable(_ url: URL, initialSize: Int64) -> Bool {
        guard settleSeconds > 0 else { return true }
        Thread.sleep(forTimeInterval: settleSeconds)
        guard let now = size(of: url) else { return false }
        return now == initialSize
    }

    /// Name of a process holding the file open, ignoring indexers and previewers.
    public func openingProcess(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "cn", "--", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil // lsof unavailable: fall back to the size-stability check alone.
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("c") {
            let name = String(line.dropFirst())
            if name.isEmpty || ignoreProcesses.contains(name) { continue }
            if ignoreProcesses.contains(where: { name.hasPrefix($0) }) { continue }
            return name
        }
        return nil
    }

    private func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    /// True when any ancestor up to the home directory is an Obsidian vault, meaning it
    /// contains a `.obsidian` directory.
    func isInsideObsidianVault(_ url: URL) -> Bool {
        var directory = url.deletingLastPathComponent().standardizedFileURL
        let stop = fileManager.homeDirectoryForCurrentUser.deletingLastPathComponent().standardizedFileURL.path
        while directory.path != "/", directory.path != stop {
            let key = directory.path
            if let cached = vaultCache[key] {
                if cached { return true }
            } else {
                let marker = directory.appendingPathComponent(".obsidian", isDirectory: true)
                let isVault = fileManager.fileExists(atPath: marker.path)
                vaultCache[key] = isVault
                if isVault { return true }
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { break }
            directory = parent
        }
        return false
    }
}
