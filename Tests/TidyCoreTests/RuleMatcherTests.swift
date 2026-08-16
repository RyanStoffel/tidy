import XCTest
@testable import TidyCore

final class RuleMatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestSupport.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScreenshotPatternCapturesFeedTheDestination() throws {
        let desktop = try TestSupport.makeDirectory(root.appendingPathComponent("Desktop"))
        let file = try TestSupport.makeFile(desktop.appendingPathComponent("Screenshot 2026-08-16 at 1.02.03 PM.png"))
        let config = Config(
            settleSeconds: 0,
            rules: [
                Rule(
                    name: "Screenshots",
                    watch: [desktop.path],
                    match: Match(namePattern: #"^Screen ?shot (?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2}) at .+\.png$"#),
                    destination: root.appendingPathComponent("Pictures/Screenshots").path + "/{year}/{month}"
                )
            ]
        )
        let result = RuleMatcher(config: config).match(try TestSupport.facts(file), triggers: [.event])
        XCTAssertEqual(
            result?.destinationDirectory.path,
            root.appendingPathComponent("Pictures/Screenshots/2026/08").path
        )
    }

    func testNonScreenshotPngOnDesktopIsLeftAlone() throws {
        let desktop = try TestSupport.makeDirectory(root.appendingPathComponent("Desktop"))
        let file = try TestSupport.makeFile(desktop.appendingPathComponent("logo.png"))
        let config = Config(
            settleSeconds: 0,
            rules: [
                Rule(
                    name: "Screenshots",
                    watch: [desktop.path],
                    match: Match(namePattern: #"^Screen ?shot (?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2}) at .+\.png$"#),
                    destination: root.path + "/Pictures/{year}"
                )
            ]
        )
        XCTAssertNil(RuleMatcher(config: config).match(try TestSupport.facts(file), triggers: [.event]))
    }

    func testFirstMatchingRuleWinsAndCatchAllTakesTheRest() throws {
        let downloads = try TestSupport.makeDirectory(root.appendingPathComponent("Downloads"))
        let config = Config(settleSeconds: 0, rules: TestSupport.downloadRules(in: downloads))
        let matcher = RuleMatcher(config: config)

        let script = try TestSupport.makeFile(downloads.appendingPathComponent("train.py"))
        XCTAssertEqual(matcher.match(try TestSupport.facts(script), triggers: [.event])?.rule.name, "code")

        let unknown = try TestSupport.makeFile(downloads.appendingPathComponent("firmware.bin"))
        XCTAssertEqual(matcher.match(try TestSupport.facts(unknown), triggers: [.event])?.rule.name, "other")

        let extensionless = try TestSupport.makeFile(downloads.appendingPathComponent("Makefile"))
        XCTAssertEqual(matcher.match(try TestSupport.facts(extensionless), triggers: [.event])?.rule.name, "other")
    }

    func testDirectoriesAreIgnoredUnlessTheRuleOptsIn() throws {
        let downloads = try TestSupport.makeDirectory(root.appendingPathComponent("Downloads"))
        let folder = try TestSupport.makeDirectory(downloads.appendingPathComponent("project"))
        var rules = TestSupport.downloadRules(in: downloads)
        let matcher = RuleMatcher(config: Config(settleSeconds: 0, rules: rules))
        XCTAssertNil(matcher.match(try TestSupport.facts(folder), triggers: [.event]))

        rules[rules.count - 1].includeDirectories = true
        let permissive = RuleMatcher(config: Config(settleSeconds: 0, rules: rules))
        XCTAssertEqual(permissive.match(try TestSupport.facts(folder), triggers: [.event])?.rule.name, "other")
    }

    func testCourseCodesMatchAcrossSpacingAndCase() throws {
        let documents = try TestSupport.makeDirectory(root.appendingPathComponent("Documents"))
        let config = Config(
            settleSeconds: 0,
            courseTerm: "FA26",
            courseCodes: ["CS10", "CS101", "MATH-241", "ENGR 310"],
            rules: [
                Rule(
                    name: "School",
                    watch: [documents.path],
                    match: Match(extensions: ["pdf", "docx"], requiresCourseCode: true),
                    destination: root.path + "/School/{term}/Courses/{course}"
                )
            ]
        )
        let matcher = RuleMatcher(config: config)

        let cases: [(String, String)] = [
            ("cs101-hw3.pdf", "CS101"),          // lowercase, dash
            ("MATH 241 Syllabus.pdf", "MATH-241"), // space in filename, dash in config
            ("engr-310_lab.docx", "ENGR 310"),   // dash in filename, space in config
            ("midterm CS10 review.pdf", "CS10"), // shorter code still reachable
        ]
        for (name, expected) in cases {
            let file = try TestSupport.makeFile(documents.appendingPathComponent(name))
            let result = matcher.match(try TestSupport.facts(file), triggers: [.event])
            XCTAssertEqual(
                result?.destinationDirectory.path,
                root.appendingPathComponent("School/FA26/Courses/\(expected)").path,
                "for \(name)"
            )
        }
    }

    func testFileWithoutACourseCodeIsNotClaimed() throws {
        let documents = try TestSupport.makeDirectory(root.appendingPathComponent("Documents"))
        let file = try TestSupport.makeFile(documents.appendingPathComponent("lease agreement.pdf"))
        let config = Config(
            settleSeconds: 0,
            courseCodes: ["CS101"],
            rules: [
                Rule(
                    name: "School",
                    watch: [documents.path],
                    match: Match(extensions: ["pdf"], requiresCourseCode: true),
                    destination: root.path + "/School/{course}"
                )
            ]
        )
        XCTAssertNil(RuleMatcher(config: config).match(try TestSupport.facts(file), triggers: [.event]))
    }

    func testIdleRuleNeedsBothTimestampsOld() throws {
        let folder = try TestSupport.makeDirectory(root.appendingPathComponent("Code"))
        let stale = try TestSupport.makeFile(folder.appendingPathComponent("old.py"))
        let recentlyRead = try TestSupport.makeFile(folder.appendingPathComponent("revisited.py"))
        let now = Date()
        TestSupport.setTimes(stale, modified: now.addingTimeInterval(-60 * 86_400), accessed: now.addingTimeInterval(-45 * 86_400))
        TestSupport.setTimes(recentlyRead, modified: now.addingTimeInterval(-60 * 86_400), accessed: now.addingTimeInterval(-86_400))

        let config = Config(
            settleSeconds: 0,
            rules: [
                Rule(
                    name: "Archive",
                    trigger: .daily,
                    watch: [folder.path],
                    match: Match(minIdleDays: 30),
                    destination: root.path + "/Archive/{sourceFolder}"
                )
            ]
        )
        let matcher = RuleMatcher(config: config)
        XCTAssertEqual(
            matcher.match(try TestSupport.facts(stale), triggers: [.event, .daily], now: now)?.destinationDirectory.path,
            root.appendingPathComponent("Archive/Code").path
        )
        XCTAssertNil(matcher.match(try TestSupport.facts(recentlyRead), triggers: [.event, .daily], now: now))
    }

    func testDailyRulesDoNotFireOnEvents() throws {
        let folder = try TestSupport.makeDirectory(root.appendingPathComponent("Code"))
        let file = try TestSupport.makeFile(folder.appendingPathComponent("old.py"))
        let now = Date()
        TestSupport.setTimes(file, modified: now.addingTimeInterval(-90 * 86_400), accessed: now.addingTimeInterval(-90 * 86_400))
        let config = Config(
            settleSeconds: 0,
            rules: [
                Rule(
                    name: "Archive",
                    trigger: .daily,
                    watch: [folder.path],
                    match: Match(minIdleDays: 30),
                    destination: root.path + "/Archive/{sourceFolder}"
                )
            ]
        )
        XCTAssertNil(RuleMatcher(config: config).match(try TestSupport.facts(file), triggers: [.event], now: now))
    }

    func testUnknownTokenIsReportedAndStopsTheRule() throws {
        let downloads = try TestSupport.makeDirectory(root.appendingPathComponent("Downloads"))
        let file = try TestSupport.makeFile(downloads.appendingPathComponent("note.txt"))
        let config = Config(
            settleSeconds: 0,
            rules: [
                Rule(
                    name: "Typo",
                    watch: [downloads.path],
                    destination: root.path + "/Sorted/{semester}"
                )
            ]
        )
        let matcher = RuleMatcher(config: config)
        XCTAssertNil(matcher.match(try TestSupport.facts(file), triggers: [.event]))
        XCTAssertEqual(matcher.warnings(), ["Typo: destination uses unknown token {semester}"])
    }

    func testRuleThatWouldMoveAFileOntoItselfIsSkipped() throws {
        let downloads = try TestSupport.makeDirectory(root.appendingPathComponent("Downloads"))
        let file = try TestSupport.makeFile(downloads.appendingPathComponent("note.txt"))
        let config = Config(
            settleSeconds: 0,
            rules: [Rule(name: "Loop", watch: [downloads.path], destination: downloads.path)]
        )
        XCTAssertNil(RuleMatcher(config: config).match(try TestSupport.facts(file), triggers: [.event]))
    }

    func testTokenValuesCannotEscapeIntoExtraPathComponents() {
        XCTAssertEqual(
            RuleMatcher.substitute("~/Sorted/{course}", values: ["course": "CS101/../.."]),
            "~/Sorted/CS101-..-.."
        )
    }
}
