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

    private var minimal: String {
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

    func testSummaryShowsEvaluationOrderTriggerAndDisabledRules() throws {
        try write(minimal)

        let snapshot = try editor.load()

        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.summary.map(\.id), [1, 2])
        XCTAssertEqual(snapshot.summary.map(\.name), ["Inbox", "Parked"])
        XCTAssertEqual(snapshot.summary.map(\.trigger), ["event", "daily"])
        XCTAssertEqual(snapshot.summary.map(\.enabled), [true, false])
        XCTAssertEqual(snapshot.summary.first?.destination, "~/Downloads/Random")
    }

    func testWarningsSurfaceWithoutFailingValidation() {
        let snapshot = editor.inspect("""
        { "rules": [ { "name": "Typo", "watch": ["~/Downloads"], "destination": "~/Sorted/{semester}" } ] }
        """)

        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.warnings, ["Typo: destination uses unknown token {semester}"])
    }

    func testSyntaxErrorIsReportedAndNothingIsWritten() throws {
        try write(minimal)
        _ = try editor.load()
        let broken = minimal.replacingOccurrences(of: "\"rules\"", with: "\"rules\"  ,,")

        let snapshot = editor.inspect(broken)
        XCTAssertFalse(snapshot.isValid)
        XCTAssertTrue(snapshot.error?.hasPrefix("invalid JSON:") == true, snapshot.error ?? "")

        XCTAssertThrowsError(try editor.save(broken)) { error in
            guard case RulesEditorError.invalid = error else {
                return XCTFail("expected .invalid, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), minimal)
    }

    func testMissingRequiredKeyNamesTheRule() {
        let snapshot = editor.inspect("""
        { "rules": [ { "name": "Nowhere", "watch": ["~/Downloads"] } ] }
        """)

        XCTAssertEqual(snapshot.error, "missing \"destination\" at rules[0]")
    }

    func testWrongTypeNamesTheField() {
        let snapshot = editor.inspect("""
        { "settleSeconds": "five", "rules": [] }
        """)

        XCTAssertEqual(snapshot.error, "wrong type at settleSeconds: expected Double")
    }

    func testSaveKeepsTheTextVerbatimApartFromATrailingNewline() throws {
        try write(minimal)
        _ = try editor.load()
        let edited = minimal.replacingOccurrences(of: "\"Inbox\"", with: "\"Inbox tray\"")

        try editor.save(edited)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited + "\n")
        XCTAssertEqual(try editor.load().summary.first?.name, "Inbox tray")
    }

    func testOutsideEditIsNotClobberedUnlessForced() throws {
        try write(minimal)
        _ = try editor.load()
        // Another editor writes the file after this one opened it.
        let outside = minimal.replacingOccurrences(of: "\"Inbox\"", with: "\"Outside\"")
        try write(outside)
        // The stamp has one second resolution on some filesystems.
        TestSupport.setTimes(url, modified: Date().addingTimeInterval(5), accessed: Date())

        let mine = minimal.replacingOccurrences(of: "\"Inbox\"", with: "\"Mine\"")
        XCTAssertThrowsError(try editor.save(mine)) { error in
            XCTAssertEqual(error as? RulesEditorError, .changedOnDisk)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), outside)

        try editor.save(mine, force: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), mine + "\n")
    }

    func testLoadCreatesTheDefaultFileWhenMissing() throws {
        let snapshot = try editor.load()

        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.ruleCount, Config.default.rules.count)
        XCTAssertEqual(try ConfigStore.load(from: url), Config.default)
    }
}
