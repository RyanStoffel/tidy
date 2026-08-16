import AppKit
import SwiftUI
import TidyCore

final class LogStore: ObservableObject {
    @Published var entries: [LogEntry] = []

    func reload(from log: MoveLog) {
        entries = log.recent(200)
    }
}

/// Recent activity, newest first, in a standard macOS table.
struct LogView: View {
    @ObservedObject var store: LogStore
    let logPath: String
    let onReveal: () -> Void
    let onClear: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d  HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            table
            HStack(spacing: 12) {
                Text("\(store.entries.count) entries")
                Text(logPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Button("Reveal in Finder", action: onReveal)
                Button("Clear", action: onClear)
                    .disabled(store.entries.isEmpty)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 320)
    }

    private var table: some View {
        Table(store.entries) {
            TableColumn("Time") { entry in
                Text(Self.time.string(from: entry.date)).monospacedDigit()
            }
            .width(130)

            TableColumn("Action") { entry in
                Text(action(entry.kind))
                    .foregroundStyle(entry.kind == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .help(entry.detail ?? "")
            }
            .width(60)

            TableColumn("Rule") { entry in
                Text(entry.rule).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 110, ideal: 160)

            TableColumn("File") { entry in
                Text(entry.source)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            .width(min: 140, ideal: 240)

            TableColumn("Destination") { entry in
                Text(entry.destination ?? entry.detail ?? "")
                    .foregroundStyle(entry.destination == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            .width(min: 140, ideal: 280)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if store.entries.isEmpty {
                Text("No activity yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func action(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .moved: return "moved"
        case .dryRun: return "dry run"
        case .failed: return "failed"
        }
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
                size: NSSize(width: 860, height: 460),
                minSize: NSSize(width: 620, height: 320),
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
