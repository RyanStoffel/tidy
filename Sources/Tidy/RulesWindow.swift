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
    @Published var selection: Selection = .general

    @Published var problems: [String] = []
    @Published var warnings: [String] = []
    /// The file on disk cannot be parsed; the fields cannot safely edit it.
    @Published var loadError: String?
    /// Outcome of the last save or reload.
    @Published var message: String?

    private let editor: RulesEditor
    private let onSaved: () -> Void
    /// Everything the fields do not expose, kept so a save never drops it.
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
            apply(try editor.load())
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
            message = "Changed on disk. Reload to see it."
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
        loadError = nil
        message = "Default rules loaded. Save to keep them."
        revalidate()
    }

    // MARK: - Rules

    func addRule() {
        let draft = RuleDraft(rule: Rule(name: "New rule", watch: [], destination: ""))
        drafts.append(draft)
        selection = .rule(draft.id)
        revalidate()
    }

    func duplicate(_ id: UUID) {
        guard let index = index(of: id) else { return }
        var copy = drafts[index].rule
        copy.name += " copy"
        let draft = RuleDraft(rule: copy)
        drafts.insert(draft, at: index + 1)
        selection = .rule(draft.id)
        revalidate()
    }

    func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        drafts.remove(at: index)
        if let next = drafts.indices.contains(index) ? drafts[index] : drafts.last {
            selection = .rule(next.id)
        } else {
            selection = .general
        }
        revalidate()
    }

    /// Order is the evaluation order, so moving a rule changes which one claims a file.
    func move(_ id: UUID, by offset: Int) {
        guard let index = index(of: id) else { return }
        let target = index + offset
        guard drafts.indices.contains(target) else { return }
        drafts.swapAt(index, target)
        revalidate()
    }

    func index(of id: UUID) -> Int? {
        drafts.firstIndex { $0.id == id }
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

    /// "pdf, DOCX , .doc" becomes ["pdf", "docx", "doc"].
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 236)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 540)
        .onChange(of: model.drafts) { _ in model.revalidate() }
        .onChange(of: model.courseCodes) { _ in model.revalidate() }
        .onChange(of: model.courseTerm) { _ in model.revalidate() }
        .onChange(of: model.settleSeconds) { _ in model.revalidate() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarRow(
                        title: "General",
                        badge: nil,
                        subtitle: "Semester and safety",
                        isSelected: model.selection == .general,
                        isDimmed: false
                    ) {
                        model.selection = .general
                    }

                    Text("RULES, IN ORDER")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 2)

                    ForEach(Array(model.drafts.enumerated()), id: \.element.id) { index, draft in
                        sidebarRow(
                            title: draft.rule.name.isEmpty ? "Untitled rule" : draft.rule.name,
                            badge: "\(index + 1)",
                            subtitle: subtitle(for: draft.rule),
                            isSelected: model.selection == .rule(draft.id),
                            isDimmed: !draft.rule.enabled
                        ) {
                            model.selection = .rule(draft.id)
                        }
                        .contextMenu {
                            Button("Move Up") { model.move(draft.id, by: -1) }
                                .disabled(index == 0)
                            Button("Move Down") { model.move(draft.id, by: 1) }
                                .disabled(index == model.drafts.count - 1)
                            Divider()
                            Button("Duplicate") { model.duplicate(draft.id) }
                            Button("Delete") { model.remove(draft.id) }
                        }
                    }
                }
                .padding(8)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Add Rule") { model.addRule() }
                Spacer()
                if case .rule(let id) = model.selection {
                    Button("Duplicate") { model.duplicate(id) }
                    Button("Delete") { model.remove(id) }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func subtitle(for rule: Rule) -> String {
        guard rule.enabled else { return "off" }
        return rule.trigger == .daily ? "once a day" : "when files change"
    }

    private func sidebarRow(
        title: String,
        badge: String?,
        subtitle: String,
        isSelected: Bool,
        isDimmed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Text(badge ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .frame(width: 12, alignment: .trailing)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : .clear)
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .opacity(isDimmed && !isSelected ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let loadError = model.loadError {
            unreadableFile(loadError)
        } else if case .rule(let id) = model.selection, let index = model.index(of: id) {
            RuleDetailView(
                rule: $model.drafts[index].rule,
                position: index + 1,
                total: model.drafts.count,
                onMove: { offset in model.move(id, by: offset) }
            )
        } else {
            GeneralDetailView(model: model)
        }
    }

    private func unreadableFile(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your rules file cannot be read")
                .font(.headline)
            Text(error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Text("Fix it in a text editor, or start again from the built-in rules.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open in Text Editor") { model.openInTextEditor() }
                Button("Reload") { model.reload() }
                Button("Use Default Rules") { model.restoreDefaults() }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 12)
            Button("Open in Text Editor") { model.openInTextEditor() }
            Button("Reveal in Finder") { model.revealInFinder() }
            Button("Reload") { model.reload() }
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if let problem = model.problems.first {
            Label(problem, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if let warning = model.warnings.first {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let message = model.message {
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(model.isDirty
                 ? "\(model.drafts.count) rules, unsaved changes"
                 : "\(model.drafts.count) rules")
                .foregroundStyle(.secondary)
        }
    }
}

/// Everything shared by the rules: semester substitutions and the settle window.
struct GeneralDetailView: View {
    @ObservedObject var model: RulesModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Term folder") {
                    FormField(text: $model.courseTerm, prompt: "FA26")
                }
                LabeledContent("Course codes") {
                    FormField(text: $model.courseCodes, prompt: "CS101, MATH-241")
                }
            } header: {
                Text("Semester")
            } footer: {
                Text("Used by rules whose destination contains {term} or {course}. Codes match filenames ignoring case, spaces and dashes, so CS101 also matches \"cs 101\".")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Wait for size to settle") {
                    HStack(spacing: 6) {
                        TextField("", value: $model.settleSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 58)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("A file has to hold the same size across two checks this far apart before Tidy moves it, so half-finished downloads are left alone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Rules file") {
                    Text(model.rulesPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            } header: {
                Text("File")
            } footer: {
                Text("Skipped extensions and ignored processes are not shown here. Edit those in a text editor; saving from this window keeps them.")
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

/// A text field sized and aligned the way the rest of the form expects.
struct FormField: View {
    @Binding var text: String
    let prompt: String
    var monospaced = false
    var width: CGFloat = 280

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .system(size: 12, design: .monospaced) : nil)
            .multilineTextAlignment(.leading)
            .frame(width: width)
    }
}

/// One rule, as fields rather than JSON.
struct RuleDetailView: View {
    @Binding var rule: Rule
    let position: Int
    let total: Int
    let onMove: (Int) -> Void

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
            Section {
                LabeledContent("Name") {
                    FormField(text: $rule.name, prompt: "Screenshots")
                }
                Toggle("Rule is on", isOn: $rule.enabled)
                Picker("Runs", selection: $rule.trigger) {
                    Text("When files change").tag(Rule.Trigger.event)
                    Text("Once a day").tag(Rule.Trigger.daily)
                }
                LabeledContent("Order") {
                    HStack(spacing: 8) {
                        Text("\(position) of \(total)").foregroundStyle(.secondary)
                        Button("Move Up") { onMove(-1) }
                            .disabled(position == 1)
                        Button("Move Down") { onMove(1) }
                            .disabled(position == total)
                    }
                }
            } header: {
                Text("Rule")
            } footer: {
                Text(rule.trigger == .daily
                     ? "Checked once a day, which is what age based rules want. The first rule in the list that matches a file wins, so order matters."
                     : "Reacts the moment a file lands, and is checked again once a day. The first rule in the list that matches a file wins, so order matters.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if rule.watch.isEmpty {
                    LabeledContent("Folders") {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(rule.watch.enumerated()), id: \.offset) { index, folder in
                    LabeledContent(index == 0 ? "Folders" : "") {
                        HStack(spacing: 8) {
                            Text(folder)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(folder)
                            Spacer(minLength: 8)
                            Button("Change") { changeFolder(at: index) }
                            Button("Remove") { rule.watch.remove(at: index) }
                        }
                    }
                }
                LabeledContent("") {
                    Button("Add Folder") { addFolder() }
                }
                Toggle("Also move folders, not just files", isOn: $rule.includeDirectories)
            } header: {
                Text("Watch")
            } footer: {
                Text("Only what sits directly in these folders is considered, never their subfolders.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Extensions") {
                    FormField(text: extensions, prompt: "pdf, docx, png")
                }
                LabeledContent("Filename pattern") {
                    FormField(text: namePattern, prompt: "Optional regular expression", monospaced: true)
                }
                LabeledContent("Modified at least") {
                    daysField(days(\.minAgeDays))
                }
                LabeledContent("Modified and opened at least") {
                    daysField(days(\.minIdleDays))
                }
                Toggle("Only files naming a course code", isOn: $rule.match.requiresCourseCode)
            } header: {
                Text("Match")
            } footer: {
                Text("Leave a field empty to ignore it. With everything empty the rule takes every file in the watched folders, which is what a catch-all wants.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Folder") {
                    FormField(text: $rule.destination, prompt: "~/Downloads/Code")
                }
                LabeledContent("") {
                    Button("Choose Folder") { chooseDestination() }
                }
            } header: {
                Text("Move to")
            } footer: {
                Text("Missing folders are created. Tokens: {term} {course} {sourceFolder} {name} {stem} {ext} {fileYear} {fileMonth} {fileDay}, plus any named group from the filename pattern.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func daysField(_ binding: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField("", text: binding, prompt: Text("any"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            Text("days ago").foregroundStyle(.secondary)
        }
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
                size: NSSize(width: 940, height: 620),
                minSize: NSSize(width: 820, height: 540),
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
