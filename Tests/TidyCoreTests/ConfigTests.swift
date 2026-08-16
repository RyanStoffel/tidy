import XCTest
@testable import TidyCore

final class ConfigTests: XCTestCase {
    /// The rules.json committed at the repo root is what the README documents, so it has
    /// to stay identical to the defaults written on first launch.
    func testCommittedRulesFileMatchesTheBuiltInDefault() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let committed = try ConfigStore.load(from: repoRoot.appendingPathComponent("rules.json"))
        XCTAssertEqual(committed, Config.default)
    }

    func testOmittedKeysFallBackToDefaults() throws {
        let json = """
        {
          "rules": [
            { "name": "Minimal", "watch": ["~/Downloads"], "destination": "~/Downloads/Random" }
          ]
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertEqual(config.settleSeconds, 5)
        XCTAssertEqual(config.skipExtensions, Config.defaultSkipExtensions)
        XCTAssertEqual(config.rules.first?.trigger, .event)
        XCTAssertEqual(config.rules.first?.enabled, true)
        XCTAssertEqual(config.rules.first?.includeDirectories, false)
        XCTAssertNil(config.rules.first?.match.namePattern)
    }

    func testSavedConfigRoundTrips() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rules.json")

        try ConfigStore.save(.default, to: url)

        XCTAssertEqual(try ConfigStore.load(from: url), Config.default)
    }

    func testDefaultRulesHaveNoWarnings() {
        XCTAssertEqual(RuleMatcher(config: .default).warnings(), [])
    }
}
