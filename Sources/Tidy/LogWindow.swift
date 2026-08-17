import AppKit
import SwiftUI
import TidyCore

final class LogStore: ObservableObject {
    @Published var entries: [LogEntry] = []

    func reload(from log: MoveLog) {
        entries = log.recent(200)
    }
}

/// Recent activity, newest first. Full paths live in tooltips so the columns stay readable.
struct LogView: View {
    @ObservedObject var store: LogStore
    let logPath: String
    let onReveal: () -> Void
    let onClear: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 320)
    }

    private var table: some View {
        Table(store.entries) {
            TableColumn("When") { entry in
                Text(Self.time.string(from: entry.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(126)

            TableColumn("Action") { entry in
                Text(action(entry.kind))
                    .foregroundStyle(entry.kind == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .help(entry.detail ?? action(entry.kind))
            }
            .width(66)

            TableColumn("Rule") { entry in
                Text(entry.rule).lineLimit(1).help(entry.rule)
            }
            .width(min: 110, ideal: 170, max: 240)

            TableColumn("File") { entry in
                Text(Self.name(of: entry.source))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.source)
            }
            .width(min: 130, ideal: 200)

            TableColumn("Moved to") { entry in
                if let destination = entry.destination {
                    Text(Self.folder(of: destination))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(destination)
                } else if let detail = entry.detail {
                    Text(detail).lineLimit(1).foregroundStyle(.secondary).help(detail)
                }
            }
            .width(min: 140, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if store.entries.isEmpty {
                VStack(spacing: 4) {
                    Text("Nothing moved yet").font(.headline)
                    Text("Moves show up here as soon as they happen.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(store.entries.isEmpty ? "No entries" : "\(store.entries.count) entries")
                .foregroundStyle(.secondary)
            Text(logPath)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 12)
            Button("Reveal in Finder", action: onReveal)
            Button("Clear", action: onClear)
                .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func action(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .moved: return "moved"
        case .dryRun: return "dry run"
        case .failed: return "failed"
        }
    }

    private static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

/// Owns the log window so reopening it reuses the same window.
final class LogWindowController {
    private var window: NSWindow?
    private let store = LogStore()
    private let log: MoveLog

    init(log: MoveLog) {
        self.log = log
    }

    func show() {
        store.reload(from: log)
        if window == nil {
            let view = LogView(
                store: store,
                logPath: Paths.abbreviate(log.fileURL),
                onReveal: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.log.fileURL])
                },
                onClear: { [weak self] in
                    guard let self else { return }
                    self.log.clear()
                    self.store.reload(from: self.log)
                }
            )
            window = WindowFactory.make(
                title: "Tidy Log",
                size: NSSize(width: 900, height: 460),
                minSize: NSSize(width: 720, height: 320),
                content: view
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keeps an open window current after a batch of moves.
    func refreshIfVisible() {
        guard let window, window.isVisible else { return }
        store.reload(from: log)
    }
}
