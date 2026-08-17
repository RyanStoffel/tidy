import AppKit
import SwiftUI
import TidyCore

/// Renders Tidy's windows to PNG files in-process, for README images and for reviewing the
/// interface without a screen recording permission. Reached with `--snapshot <dir>`.
enum WindowSnapshot {
    static func write(to directory: URL) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }

        let general = RulesModel(onSaved: {})
        general.reload()

        let rule = RulesModel(onSaved: {})
        rule.reload()
        if let second = rule.drafts.dropFirst().first { rule.selection = .rule(second.id) }

        let fresh = RulesModel(onSaved: {})
        fresh.reload()
        fresh.addRule()

        let logStore = LogStore()
        logStore.reload(from: sampleLog())

        let shots: [(String, NSWindow)] = [
            ("rules-general", window(
                title: "Tidy Rules",
                size: NSSize(width: 960, height: 1080),
                content: RulesView(model: general)
            )),
            ("rules-rule", window(
                title: "Tidy Rules",
                size: NSSize(width: 960, height: 1080),
                content: RulesView(model: rule)
            )),
            ("rules-new", window(
                title: "Tidy Rules",
                size: NSSize(width: 960, height: 1080),
                content: RulesView(model: fresh)
            )),
            ("log", window(
                title: "Tidy Log",
                size: NSSize(width: 900, height: 460),
                content: LogView(
                    store: logStore,
                    logPath: "~/Library/Application Support/Tidy/log.json",
                    onReveal: {},
                    onClear: {}
                )
            )),
        ]

        // A turn of the run loop so SwiftUI lays out and draws before capture.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        var failed = false
        for (name, window) in shots {
            guard let view = window.contentView, let data = png(of: view) else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                failed = true
                continue
            }
            let url = directory.appendingPathComponent("\(name).png")
            try? data.write(to: url)
            print("wrote \(url.path)")
        }
        return failed ? 1 : 0
    }

    private static func window<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = WindowFactory.make(title: title, size: size, minSize: size, content: content)
        // Offscreen, so a snapshot run does not throw windows in front of anyone.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        return window
    }

    private static func png(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Representative rows so the log window is not rendered empty.
    private static func sampleLog() -> MoveLog {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tidy-snapshot-log-\(UUID().uuidString).json")
        let log = MoveLog(url: url)
        log.append([
            LogEntry(
                date: Date().addingTimeInterval(-3600),
                rule: "Archive stale downloads",
                source: "~/Downloads/Random/old-installer.dmg",
                destination: "~/Downloads/Archive/Random/old-installer.dmg",
                kind: .failed,
                detail: "The volume is out of space."
            ),
            LogEntry(
                date: Date().addingTimeInterval(-600),
                rule: "Downloads: everything else",
                source: "~/Downloads/firmware.bin",
                destination: "~/Downloads/Random/firmware.bin",
                kind: .dryRun
            ),
            LogEntry(
                date: Date().addingTimeInterval(-240),
                rule: "Downloads: code",
                source: "~/Downloads/train.py",
                destination: "~/Downloads/Code/train (1).py",
                kind: .moved
            ),
            LogEntry(
                date: Date().addingTimeInterval(-90),
                rule: "School documents",
                source: "~/Downloads/Documents/MATH 241 midterm.pdf",
                destination: "~/Documents/School/FA26/Courses/MATH-241/MATH 241 midterm.pdf",
                kind: .moved
            ),
            LogEntry(
                date: Date().addingTimeInterval(-30),
                rule: "Screenshots",
                source: "~/Desktop/Screenshot 2026-08-16 at 9.15.42 AM.png",
                destination: "~/Pictures/Screenshots/2026/08/Screenshot 2026-08-16 at 9.15.42 AM.png",
                kind: .moved
            ),
        ])
        return log
    }
}
