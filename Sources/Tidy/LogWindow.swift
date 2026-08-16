import AppKit
import SwiftUI
import TidyCore

final class LogStore: ObservableObject {
    @Published var entries: [LogEntry] = []

    func reload(from log: MoveLog) {
        entries = log.recent(200)
    }
}

/// Recent activity, newest first. Deliberately plain: one row per action, no chrome.
struct LogView: View {
    @ObservedObject var store: LogStore
    let logPath: String
    let onClear: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d  HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.entries.isEmpty {
                Text("No activity yet.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            Divider().overlay(Color.white.opacity(0.15))
            HStack(spacing: 12) {
                Text("\(store.entries.count) entries")
                Text(logPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(Color.black)
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.time.string(from: entry.date))
                .foregroundStyle(.white.opacity(0.5))
            Text(marker(entry.kind))
                .foregroundStyle(color(entry.kind))
                .frame(width: 44, alignment: .leading)
            Text(entry.rule)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail(entry))
                .foregroundStyle(.white)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func detail(_ entry: LogEntry) -> String {
        var text = entry.source
        if let destination = entry.destination { text += "  ->  " + destination }
        if let extra = entry.detail { text += "  (" + extra + ")" }
        return text
    }

    private func marker(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .moved: return "moved"
        case .dryRun: return "dry"
        case .failed: return "failed"
        }
    }

    private func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .moved: return .white
        case .dryRun: return Color(white: 0.65)
        case .failed: return Color(red: 1, green: 0.42, blue: 0.38)
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
                onClear: { [weak self] in
                    guard let self else { return }
                    self.log.clear()
                    self.store.reload(from: self.log)
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Tidy Log"
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: view)
            window.center()
            self.window = window
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
