import Foundation
import TidyCore

/// Terminal entry points used to validate rules before letting the app move anything.
enum CommandLineMode {
    static let usage = """
    Tidy \u{2014} rule-driven file organizer.

    Running with no arguments starts the menu bar app.

      --sweep --dry-run     report what the rules would do, move nothing
      --sweep --live        apply the rules once and exit
      --rules <path>        use this rules file instead of the installed one
      --events-only         skip age-based (daily) rules
      --verbose             also report files a rule wanted but a guard held back
      --print-default-rules write the built-in rules.json to stdout
      --snapshot <dir>      render the windows to PNGs, for docs and design review
      --help                show this message
    """

    /// Returns an exit code when the arguments describe a terminal run, or nil to start the app.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if arguments.contains("--print-default-rules") {
            return printDefaultRules()
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            return WindowSnapshot.write(to: Paths.expand(arguments[index + 1]))
        }
        guard arguments.contains("--sweep") else { return nil }
        return sweep(arguments)
    }

    private static func printDefaultRules() -> Int32 {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Config.default)
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            FileHandle.standardError.write(Data("cannot encode default rules: \(error)\n".utf8))
            return 1
        }
    }

    private static func sweep(_ arguments: [String]) -> Int32 {
        let dryRun = arguments.contains("--dry-run")
        let live = arguments.contains("--live")
        guard dryRun != live else {
            FileHandle.standardError.write(Data("--sweep needs exactly one of --dry-run or --live\n".utf8))
            return 2
        }

        let config: Config
        do {
            if let index = arguments.firstIndex(of: "--rules"), index + 1 < arguments.count {
                config = try ConfigStore.load(from: Paths.expand(arguments[index + 1]))
            } else {
                config = try ConfigStore.loadOrCreate()
            }
        } catch {
            FileHandle.standardError.write(Data("cannot read rules: \(error.localizedDescription)\n".utf8))
            return 1
        }

        let organizer = Organizer(config: config, dryRun: dryRun)
        for warning in organizer.warnings() {
            print("warning: \(warning)")
        }

        let triggers: Set<Rule.Trigger> = arguments.contains("--events-only") ? [.event] : [.event, .daily]
        let verbose = arguments.contains("--verbose")
        var acted = 0
        for outcome in organizer.sweep(triggers: triggers) {
            if outcome.kind == .skipped && !verbose { continue }
            if outcome.kind != .skipped { acted += 1 }
            print(outcome.summary)
        }
        print(dryRun ? "\(acted) file(s) would be moved" : "\(acted) file(s) handled")
        return 0
    }
}
