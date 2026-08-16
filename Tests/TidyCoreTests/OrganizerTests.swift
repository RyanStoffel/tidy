import XCTest
@testable import TidyCore

final class OrganizerTests: XCTestCase {
    private var root: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        root = try TestSupport.makeTemporaryDirectory()
        downloads = try TestSupport.makeDirectory(root.appendingPathComponent("Downloads"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func config(_ rules: [Rule]? = nil) -> Config {
        Config(settleSeconds: 0, rules: rules ?? TestSupport.downloadRules(in: downloads))
    }

    func testFilesAreRoutedByExtension() throws {
        let script = try TestSupport.makeFile(downloads.appendingPathComponent("train.py"))
        let blob = try TestSupport.makeFile(downloads.appendingPathComponent("firmware.bin"))

        let outcomes = Organizer(config: config(), dryRun: false).sweep(triggers: [.event])

        XCTAssertEqual(outcomes.filter { $0.kind == .moved }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Code/train.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Random/firmware.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
    }

    func testCollisionsGetNumberedSuffixesInsteadOfOverwriting() throws {
        let code = try TestSupport.makeDirectory(downloads.appendingPathComponent("Code"))
        try TestSupport.makeFile(code.appendingPathComponent("train.py"), contents: "first")

        let organizer = Organizer(config: config(), dryRun: false)
        try TestSupport.makeFile(downloads.appendingPathComponent("train.py"), contents: "second")
        _ = organizer.sweep(triggers: [.event])
        try TestSupport.makeFile(downloads.appendingPathComponent("train.py"), contents: "third")
        _ = organizer.sweep(triggers: [.event])

        XCTAssertEqual(try String(contentsOf: code.appendingPathComponent("train.py")), "first")
        XCTAssertEqual(try String(contentsOf: code.appendingPathComponent("train (1).py")), "second")
        XCTAssertEqual(try String(contentsOf: code.appendingPathComponent("train (2).py")), "third")
    }

    func testDryRunReportsTheTargetWithoutTouchingAnything() throws {
        let script = try TestSupport.makeFile(downloads.appendingPathComponent("train.py"))

        let outcomes = Organizer(config: config(), dryRun: true).sweep(triggers: [.event])

        XCTAssertEqual(outcomes.map(\.kind), [.dryRun])
        XCTAssertEqual(outcomes.first?.destination?.path, downloads.appendingPathComponent("Code/train.py").path)
        XCTAssertEqual(outcomes.first?.logEntry?.kind, .dryRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Code").path))
    }

    func testPartialDownloadsAndHiddenFilesAreNeverTouched() throws {
        let partial = try TestSupport.makeFile(downloads.appendingPathComponent("movie.mp4.crdownload"))
        let hidden = try TestSupport.makeFile(downloads.appendingPathComponent(".DS_Store"))

        let outcomes = Organizer(config: config(), dryRun: false).sweep(triggers: [.event])

        XCTAssertTrue(outcomes.allSatisfy { $0.kind == .skipped })
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))
    }

    func testFilesInsideAnObsidianVaultAreNeverTouched() throws {
        let vault = try TestSupport.makeDirectory(downloads.appendingPathComponent("Notes"))
        try TestSupport.makeDirectory(vault.appendingPathComponent(".obsidian"))
        let note = try TestSupport.makeFile(vault.appendingPathComponent("todo.md"))

        let rules = [
            Rule(
                name: "notes",
                watch: [vault.path],
                match: Match(extensions: ["md"]),
                destination: root.path + "/Sorted"
            )
        ]
        let outcomes = Organizer(config: config(rules), dryRun: false).sweep(triggers: [.event])

        XCTAssertEqual(outcomes.map(\.kind), [.skipped])
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    }

    func testSchoolRoutingWinsOverArchivingForAStaleDocument() throws {
        let documents = try TestSupport.makeDirectory(downloads.appendingPathComponent("Documents"))
        let old = try TestSupport.makeFile(documents.appendingPathComponent("CS101 final project.pdf"))
        let now = Date()
        TestSupport.setTimes(old, modified: now.addingTimeInterval(-90 * 86_400), accessed: now.addingTimeInterval(-90 * 86_400))

        let rules = [
            Rule(
                name: "School documents",
                watch: [documents.path],
                match: Match(extensions: ["pdf"], requiresCourseCode: true),
                destination: root.path + "/School/{term}/Courses/{course}"
            ),
            Rule(
                name: "Archive stale downloads",
                trigger: .daily,
                watch: [documents.path],
                match: Match(minIdleDays: 30),
                destination: downloads.path + "/Archive/{sourceFolder}"
            ),
        ]
        let config = Config(settleSeconds: 0, courseTerm: "FA26", courseCodes: ["CS101"], rules: rules)
        let outcomes = Organizer(config: config, dryRun: false).sweep(triggers: [.event, .daily], now: now)

        XCTAssertEqual(outcomes.map(\.rule), ["School documents"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("School/FA26/Courses/CS101/CS101 final project.pdf").path
            )
        )
    }

    func testLogKeepsNewestEntriesUpToTheLimit() throws {
        let log = MoveLog(url: root.appendingPathComponent("log.json"), limit: 3)
        log.append((1...5).map {
            LogEntry(rule: "r", source: "file\($0)", destination: "dest", kind: .moved)
        })

        XCTAssertEqual(log.recent().map(\.source), ["file5", "file4", "file3"])
        XCTAssertEqual(
            MoveLog(url: root.appendingPathComponent("log.json"), limit: 3).recent().map(\.source),
            ["file5", "file4", "file3"]
        )
    }
}
