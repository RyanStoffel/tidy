import AppKit
import SwiftUI
import TidyCore

/// Editing state for rules.json. Validation runs on every keystroke; the file is only
/// written when the text parses.
final class RulesModel: ObservableObject {
    @Published var text: String = "" {
        didSet { snapshot = editor.inspect(text) }
    }
    @Published var snapshot = RulesSnapshot.empty
    /// Result of the last save, or a read failure.
    @Published var message: String?

    private let editor: RulesEditor
    private let onSaved: () -> Void

    init(editor: RulesEditor = RulesEditor(), onSaved: @escaping () -> Void) {
        self.editor = editor
        self.onSaved = onSaved
    }

    var rulesPath: String { Paths.abbreviate(editor.url) }

    func reload() {
        do {
            text = try editor.load().text
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func save() {
        do {
            try editor.save(text)
            message = "Saved"
            onSaved()
        } catch RulesEditorError.changedOnDisk {
            resolveConflict()
        } catch {
            message = error.localizedDescription
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([editor.url])
    }

    /// Someone edited rules.json in another editor while this window was open.
    private func resolveConflict() {
        let alert = NSAlert()
        alert.messageText = "rules.json changed on disk"
        alert.informativeText = "Another editor wrote the file after this window opened."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try editor.save(text, force: true)
                message = "Saved"
                onSaved()
            } catch {
                message = error.localizedDescription
            }
        case .alertSecondButtonReturn:
            reload()
        default:
            message = "Not saved"
        }
    }
}

struct RulesView: View {
    @ObservedObject var model: RulesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            rules
            editor
            footer
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 420)
    }

    /// Evaluation order, because the first matching rule wins.
    private var rules: some View {
        Table(model.snapshot.summary) {
            TableColumn("#") { rule in
                Text("\(rule.id)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(24)

            TableColumn("Trigger") { rule in
                Text(rule.trigger).foregroundStyle(.secondary)
            }
            .width(60)

            TableColumn("Rule") { rule in
                Text(rule.enabled ? rule.name : "\(rule.name)  (off)")
                    .foregroundStyle(rule.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Watches") { rule in
                Text(rule.watch).lineLimit(1).truncationMode(.head).help(rule.watch)
            }
            .width(min: 130, ideal: 200)

            TableColumn("Destination") { rule in
                Text(rule.destination).lineLimit(1).truncationMode(.head).help(rule.destination)
            }
            .width(min: 150, ideal: 260)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: 150)
        .overlay {
            if model.snapshot.summary.isEmpty {
                Text(model.snapshot.isValid ? "No rules" : "Rules cannot be read while the file is invalid")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.snapshot.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            TextEditor(text: $model.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.snapshot.error {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("\(model.snapshot.ruleCount) rules")
                if let message = model.message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Reveal in Finder", action: model.revealInFinder)
            Button("Reload", action: model.reload)
            Button("Save", action: model.save)
                .buttonStyle(.borderedProminent)
                .disabled(!model.snapshot.isValid)
        }
        .font(.callout)
    }
}

/// Owns the rules window and its Command-S handling.
final class RulesWindowController: NSObject, NSWindowDelegate {
    private let model: RulesModel
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(onSaved: @escaping () -> Void) {
        model = RulesModel(onSaved: onSaved)
        super.init()
    }

    func show() {
        model.reload()
        if window == nil {
            let window = WindowFactory.make(
                title: "Tidy Rules",
                size: NSSize(width: 900, height: 640),
                minSize: NSSize(width: 680, height: 420),
                content: RulesView(model: model)
            )
            window.delegate = self
            self.window = window
        }
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    /// An accessory app has no menu bar, so Command-S is wired up by hand. SwiftUI's
    /// keyboardShortcut alone never fires without a File menu to host it.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "s"
            else { return event }
            self.model.save()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
