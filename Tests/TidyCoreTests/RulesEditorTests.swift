import XCTest
@testable import TidyCore

final class RulesEditorTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var editor: RulesEditor!

    override func setUpWithError() throws {
        directory = try TestSupport.makeTemporaryDirectory()
        url = directory.appendingPathComponent("rules.json")
        editor = RulesEditor(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private var twoRules: String {
        """
        {
          "rules": [
            { "name": "Inbox", "watch": ["~/Downloads"], "destination": "~/Downloads/Random" },
            { "name": "Parked", "enabled": false, "trigger": "daily", "watch": ["~/Downloads/Random"],
              "match": { "minIdleDays": 30 }, "destination": "~/Downloads/Archive/{sourceFolder}" }
          ]
        }
        """
    }

    func testLoadKeepsRuleOrderAndPerRuleSettings() throws {
        try write(twoRules)

        let config = try editor.load()

        XCTAssertEqual(config.rules.map(\.name), ["Inbox", "Parked"])
        XCTAssertEqual(config.rules.map(\.trigger), [.event, .daily])
        XCTAssertEqual(config.rules.map(\.enabled), [true, false])
        XCTAssertEqual(config.rules.last?.match.minIdleDays, 30)
    }

    func testUnreadableFileReportsTheLocation() throws {
        try write("{ \"rules\": [ { \"name\": \"Nowhere\", \"watch\": [\"~/Downloads\"] } ] }")

        XCTAssertThrowsError(try editor.load()) { error in
            XCTAssertEqual(error as? RulesEditorError, .invalid("missing \"destination\" at rules[0]"))
        }
    }

    func testSyntaxErrorIsReportedAsInvalid() throws {
        try write("{ \"rules\": [ ,, ] }")

        XCTAssertThrowsError(try editor.load()) { error in
            guard case RulesEditorError.invalid(let message) = error else {
                return XCTFail("expected .invalid, got \(error)")
            }
            XCTAssertTrue(message.hasPrefix("invalid JSON:"), message)
        }
    }

    func testProblemsBlockRulesThatCanNeverRun() {
        let config = Config(rules: [
            Rule(name: "  ", watch: ["~/Downloads"], destination: "~/Sorted"),
            Rule(name: "No folder", watch: [], destination: "~/Sorted"),
            Rule(name: "No destination", watch: ["~/Downloads"], destination: " "),
            Rule(name: "Fine", watch: ["~/Downloads"], destination: "~/Sorted"),
        ])

        XCTAssertEqual(RulesEditor.problems(in: config), [
            "Rule 1 needs a name",
            "No folder needs at least one folder to watch",
            "No destination needs a destination",
        ])
    }

    func testSaveRefusesRulesWithProblems() throws {
        try write(twoRules)
        _ = try editor.load()
        let broken = Config(rules: [Rule(name: "Nowhere", watch: [], destination: "")])

        XCTAssertThrowsError(try editor.save(broken)) { error in
            guard case RulesEditorError.invalid = error else {
                return XCTFail("expected .invalid, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), twoRules)
    }

    func testWarningsDoNotBlockSaving() throws {
        try write(twoRules)
        var config = try editor.load()
        config.rules.append(Rule(name: "Typo", watch: ["~/Downloads"], destination: "~/Sorted/{semester}"))

        XCTAssertEqual(RulesEditor.warnings(in: config), ["Typo: destination uses unknown token {semester}"])
        XCTAssertNoThrow(try editor.save(config))
        XCTAssertEqual(try ConfigStore.load(from: url).rules.count, 3)
    }

    func testSaveKeepsFieldsTheGuiDoesNotShow() throws {
        try write("""
        {
          "skipExtensions": ["crdownload", "myext"],
          "ignoreProcesses": ["mds", "MyApp"],
          "rules": [ { "name": "Inbox", "watch": ["~/Downloads"], "destination": "~/Downloads/Random" } ]
        }
        """)
        var config = try editor.load()
        config.rules[0].name = "Inbox tray"

        try editor.save(config)

        let saved = try ConfigStore.load(from: url)
        XCTAssertEqual(saved.skipExtensions, ["crdownload", "myext"])
        XCTAssertEqual(saved.ignoreProcesses, ["mds", "MyApp"])
        XCTAssertEqual(saved.rules.first?.name, "Inbox tray")
    }

    func testOutsideEditIsNotClobberedUnlessForced() throws {
        try write(twoRules)
        var mine = try editor.load()
        mine.courseTerm = "SP27"

        // Another editor writes the file after this one opened it.
        try write(twoRules.replacingOccurrences(of: "\"Inbox\"", with: "\"Outside\""))
        TestSupport.setTimes(url, modified: Date().addingTimeInterval(5), accessed: Date())

        XCTAssertThrowsError(try editor.save(mine)) { error in
            XCTAssertEqual(error as? RulesEditorError, .changedOnDisk)
        }
        XCTAssertEqual(try ConfigStore.load(from: url).rules.first?.name, "Outside")

        try editor.save(mine, force: true)
        XCTAssertEqual(try ConfigStore.load(from: url).courseTerm, "SP27")
    }

    func testLoadCreatesTheDefaultFileWhenMissing() throws {
        let config = try editor.load()

        XCTAssertEqual(config, Config.default)
        XCTAssertEqual(try ConfigStore.load(from: url), Config.default)
    }

    func testSavingTwiceInARowDoesNotTripTheConflictCheck() throws {
        var config = try editor.load()
        config.courseTerm = "SP27"
        try editor.save(config)

        config.courseTerm = "SU27"
        XCTAssertNoThrow(try editor.save(config))
        XCTAssertEqual(try ConfigStore.load(from: url).courseTerm, "SU27")
    }
}
