import AppKit
import SwiftUI
import TidyCore

/// A rule plus a stable identity, so the sidebar keeps its selection while the rule's own
/// fields are being edited. The identity is never written to disk.
struct RuleDraft: Identifiable, Equatable {
    let id = UUID()
    var rule: Rule
}

/// Editing state for the rules window. Holds the rules as drafts, reports problems and
/// warnings, and writes rules.json only when the rules can actually run.
final class RulesModel: ObservableObject {
    enum Selection: Hashable {
        case general
        case rule(UUID)
    }

    @Published var drafts: [RuleDraft] = []
    @Published var courseTerm = ""
    @Published var courseCodes = ""
    @Published var settleSeconds: Double = 5
    @Published var selection: Selection? = .general

    @Published var problems: [String] = []
    @Published var warnings: [String] = []
    /// The file on disk cannot be parsed; the GUI cannot safely edit it.
    @Published var loadError: String?
    /// Outcome of the last save or reload.
    @Published var message: String?

    private let editor: RulesEditor
    private let onSaved: () -> Void
    /// Everything the GUI does not expose, kept so a save never drops it.
    private var loaded = Config.default

    init(editor: RulesEditor = RulesEditor(), onSaved: @escaping () -> Void) {
        self.editor = editor
        self.onSaved = onSaved
    }

    var rulesPath: String { Paths.abbreviate(editor.url) }
    var isDirty: Bool { config != loaded }
    var canSave: Bool { loadError == nil && problems.isEmpty && isDirty }

    /// The rules as they would be written right now.
    var config: Config {
        var config = loaded
        config.courseTerm = courseTerm
        config.courseCodes = Self.parseList(courseCodes, lowercased: false)
        config.settleSeconds = settleSeconds
        config.rules = drafts.map(\.rule)
        return config
    }

    // MARK: - File

    func reload() {
        do {
            let config = try editor.load()
            apply(config)
            loadError = nil
            message = nil
        } catch {
            loadError = error.localizedDescription
            message = nil
        }
        revalidate()
    }

    /// Re-reads the file if it changed underneath an unmodified window, and says so when
    /// there are unsaved edits rather than throwing them away.
    func reloadIfChangedOnDisk() {
        guard editor.changedOnDisk else { return }
        if isDirty, loadError == nil {
            message = "rules.json changed on disk. Reload to see it."
        } else {
            reload()
            message = "Reloaded"
        }
    }

    func save() {
        do {
            try editor.save(config)
            loaded = config
            message = "Saved"
            onSaved()
        } catch RulesEditorError.changedOnDisk {
            resolveConflict()
        } catch {
            message = error.localizedDescription
        }
        revalidate()
    }

    func openInTextEditor() {
        NSWorkspace.shared.open(editor.url)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([editor.url])
    }

    func restoreDefaults() {
        apply(.default)
        revalidate()
        message = "Defaults loaded, not yet saved"
        loadError = nil
    }

    // MARK: - Rules

    func addRule() {
        let draft = RuleDraft(rule: Rule(name: "New rule", watch: [], destination: ""))
        drafts.append(draft)
        selection = .rule(draft.id)
        revalidate()
    }

    func duplicate(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        var copy = drafts[index].rule
        copy.name += " copy"
        let draft = RuleDraft(rule: copy)
        drafts.insert(draft, at: index + 1)
        selection = .rule(draft.id)
        revalidate()
    }

    func remove(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        selection = drafts.indices.contains(index)
            ? .rule(drafts[index].id)
            : drafts.last.map { .rule($0.id) } ?? .general
        revalidate()
    }

    /// Order is the evaluation order, so moving a rule changes which one claims a file.
    func move(from source: IndexSet, to destination: Int) {
        drafts.move(fromOffsets: source, toOffset: destination)
        revalidate()
    }

    func index(of id: UUID) -> Int? {
        drafts.firstIndex(where: { $0.id == id })
    }

    func revalidate() {
        let config = config
        problems = RulesEditor.problems(in: config)
        warnings = RulesEditor.warnings(in: config)
    }

    // MARK: - Helpers

    private func apply(_ config: Config) {
        loaded = config
        courseTerm = config.courseTerm
        courseCodes = config.courseCodes.joined(separator: ", ")
        settleSeconds = config.settleSeconds
        drafts = config.rules.map { RuleDraft(rule: $0) }
        if case .rule(let id) = selection, index(of: id) == nil {
            selection = .general
        }
    }

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
                try editor.save(config, force: true)
                loaded = config
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

    /// "pdf, DOCX , doc" becomes ["pdf", "docx", "doc"]; empty becomes an empty list.
    static func parseList(_ text: String, lowercased: Bool) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { part -> String in
                var value = part.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix(".") { value.removeFirst() }
                return lowercased ? value.lowercased() : value
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Presents a folder chooser and returns a tilde path, matching what rules.json holds.
    static func chooseFolder(startingAt path: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let path, !path.isEmpty { panel.directoryURL = Paths.expand(path) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Paths.abbreviate(url)
    }
}

// MARK: - Window

struct RulesView: View {
    @ObservedObject var model: RulesModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .safeAreaInset(edge: .bottom) { footer }
        .frame(minWidth: 820, minHeight: 520)
        .onChange(of: model.drafts) { _ in model.revalidate() }
        .onChange(of: model.courseCodes) { _ in model.revalidate() }
        .onChange(of: model.courseTerm) { _ in model.revalidate() }
        .onChange(of: model.settleSeconds) { _ in model.revalidate() }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section {
                Text("General").tag(RulesModel.Selection.general)
            }
            Section("Rules, in order") {
                ForEach(model.drafts) { draft in
                    row(draft)
                        .tag(RulesModel.Selection.rule(draft.id))
                        .contextMenu {
                            Button("Duplicate") { model.duplicate(draft.id) }
                            Button("Delete") { model.remove(draft.id) }
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button("Add Rule") { model.addRule() }
                Spacer()
                if case .rule(let id) = model.selection {
                    Button("Duplicate") { model.duplicate(id) }
                    Button("Delete") { model.remove(id) }
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func row(_ draft: RuleDraft) -> some View {
        let index = model.index(of: draft.id)
        return HStack(spacing: 8) {
            if let index {
                Toggle("", isOn: $model.drafts[index].rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(draft.rule.enabled ? "Rule is on" : "Rule is off")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.rule.name.isEmpty ? "Untitled rule" : draft.rule.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(draft.rule.trigger == .daily ? "once a day" : "when files change")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(draft.rule.enabled ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let loadError = model.loadError {
            unreadableFile(loadError)
        } else {
            switch model.selection {
            case .rule(let id):
                if let index = model.index(of: id) {
                    RuleDetailView(rule: $model.drafts[index].rule, position: index + 1)
                } else {
                    Text("Select a rule").foregroundStyle(.secondary)
                }
            default:
                GeneralDetailView(model: model)
            }
        }
    }

    private func unreadableFile(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("rules.json cannot be read")
                .font(.headline)
            Text(error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Text("Fix it in a text editor, or replace it with the built-in rules.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open in Text Editor") { model.openInTextEditor() }
                Button("Reload") { model.reload() }
                Button("Use Default Rules") { model.restoreDefaults() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 8)
            Button("Open in Text Editor") { model.openInTextEditor() }
            Button("Reveal in Finder") { model.revealInFinder() }
            Button("Reload") { model.reload() }
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if let problem = model.problems.first {
            Text(problem).foregroundStyle(.red).lineLimit(1)
        } else if let warning = model.warnings.first {
            Text(warning).foregroundStyle(.orange).lineLimit(1)
        } else if let message = model.message {
            Text(message).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("\(model.drafts.count) rules\(model.isDirty ? ", unsaved changes" : "")")
                .foregroundStyle(.secondary)
        }
    }
}

/// Everything shared by the rules: semester substitutions and the settle window.
struct GeneralDetailView: View {
    @ObservedObject var model: RulesModel

    var body: some View {
        Form {
            Section("Semester") {
                TextField("Term folder", text: $model.courseTerm)
                TextField("Course codes", text: $model.courseCodes, axis: .vertical)
                    .lineLimit(2...4)
                Text("Used by rules whose destination contains {term} or {course}. Codes match filenames ignoring case, spaces and dashes, so CS101 also matches \"cs 101\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Safety") {
                TextField("Wait for size to settle", value: $model.settleSeconds, format: .number)
                    .frame(maxWidth: 120)
                Text("Seconds between the two size checks that decide a download finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("File") {
                LabeledContent("Rules file", value: model.rulesPath)
                Text("Skipped extensions and ignored processes are not shown here. Edit them in the text editor; saving from this window keeps them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(model.warnings, id: \.self) { warning in
                        Text(warning).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One rule, as fields rather than JSON.
struct RuleDetailView: View {
    @Binding var rule: Rule
    let position: Int

    private var extensions: Binding<String> {
        Binding(
            get: { (rule.match.extensions ?? []).joined(separator: ", ") },
            set: {
                let list = RulesModel.parseList($0, lowercased: true)
                rule.match.extensions = list.isEmpty ? nil : list
            }
        )
    }

    private var namePattern: Binding<String> {
        Binding(
            get: { rule.match.namePattern ?? "" },
            set: { rule.match.namePattern = $0.isEmpty ? nil : $0 }
        )
    }

    private func days(_ keyPath: WritableKeyPath<Match, Int?>) -> Binding<String> {
        Binding(
            get: { rule.match[keyPath: keyPath].map(String.init) ?? "" },
            set: { rule.match[keyPath: keyPath] = Int($0.trimmingCharacters(in: .whitespaces)) }
        )
    }

    var body: some View {
        Form {
            Section("Rule \(position)") {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
                Picker("Runs", selection: $rule.trigger) {
                    Text("When files change").tag(Rule.Trigger.event)
                    Text("Once a day").tag(Rule.Trigger.daily)
                }
                Text(rule.trigger == .daily
                     ? "Age based rules belong here; they are checked on the daily timer."
                     : "Reacts to file system events, and is also checked once a day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Watch") {
                ForEach(Array(rule.watch.enumerated()), id: \.offset) { index, folder in
                    HStack {
                        Text(folder).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Change") { changeFolder(at: index) }
                        Button("Remove") { rule.watch.remove(at: index) }
                    }
                }
                Button("Add Folder") { addFolder() }
                Toggle("Also move folders, not just files", isOn: $rule.includeDirectories)
                Text("Only the direct contents of these folders are considered, never subfolders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Match") {
                TextField("Extensions", text: extensions, prompt: Text("pdf, docx, png. Empty matches every file"))
                TextField("Filename pattern", text: namePattern, prompt: Text("Optional regex"))
                    .font(.system(.body, design: .monospaced))
                TextField("Modified at least this many days ago", text: days(\.minAgeDays), prompt: Text("Any"))
                    .frame(maxWidth: 260)
                TextField("Modified and opened at least this many days ago", text: days(\.minIdleDays), prompt: Text("Any"))
                    .frame(maxWidth: 260)
                Toggle("Only files naming a course code", isOn: $rule.match.requiresCourseCode)
            }

            Section("Destination") {
                TextField("Folder", text: $rule.destination, prompt: Text("~/Downloads/Code"))
                Button("Choose Folder") { chooseDestination() }
                Text("Tokens: {term} {course} {sourceFolder} {name} {stem} {ext} {fileYear} {fileMonth} {fileDay}, plus any named group from the filename pattern. Missing folders are created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        guard let folder = RulesModel.chooseFolder(startingAt: rule.watch.last) else { return }
        if !rule.watch.contains(folder) { rule.watch.append(folder) }
    }

    private func changeFolder(at index: Int) {
        guard let folder = RulesModel.chooseFolder(startingAt: rule.watch[index]) else { return }
        rule.watch[index] = folder
    }

    private func chooseDestination() {
        guard let folder = RulesModel.chooseFolder(startingAt: rule.destination) else { return }
        rule.destination = folder
    }
}

/// Owns the rules window, its Command-S handling, and reload-on-focus.
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
                size: NSSize(width: 940, height: 640),
                minSize: NSSize(width: 820, height: 520),
                content: RulesView(model: model)
            )
            window.delegate = self
            self.window = window
        }
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Coming back from the text editor should show what was saved there.
    func windowDidBecomeKey(_ notification: Notification) {
        model.reloadIfChangedOnDisk()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    /// An accessory app has no menu bar, so Command-S is wired up by hand.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "s"
            else { return event }
            if self.model.canSave { self.model.save() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
