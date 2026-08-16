import AppKit
import ServiceManagement
import TidyCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Key {
        static let enabled = "enabled"
        static let dryRun = "dryRun"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// All scanning and moving happens here, one candidate at a time.
    private let work = DispatchQueue(label: "com.ryanstoffel.tidy.work", qos: .utility)
    private let log = MoveLog()
    private lazy var logWindow = LogWindowController(log: log)
    private lazy var rulesWindow = RulesWindowController { [weak self] in
        self?.rulesSaved()
    }
    private lazy var watchers = WatchSet(queue: work) { [weak self] url in
        self?.scheduleScan(of: url)
    }

    /// Guards `organizer`, which is replaced on the main thread and used on `work`.
    private let stateLock = NSLock()
    private var organizer: Organizer?
    private var warnings: [String] = []
    private var configError: String?
    private var rulesStamp: Date?
    private var lastSummary: String?
    /// Coalesces bursts of events per directory. Only touched on `work`.
    private var pendingScans: [String: DispatchWorkItem] = [:]
    /// Failures already logged this launch, so a denied folder is not logged every sweep.
    private var loggedFailures = Set<String>()
    private var dailyTimer: Timer?
    private var reconcileTimer: Timer?

    private var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    private var isDryRun: Bool {
        get { UserDefaults.standard.bool(forKey: Key.dryRun) }
        set { UserDefaults.standard.set(newValue, forKey: Key.dryRun) }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Key.enabled: true, Key.dryRun: false])

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        loadConfig()
        startTimers()
        checkFolderAccess()
        runSweep(triggers: [.event, .daily])
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchers.cancelAll()
        dailyTimer?.invalidate()
        reconcileTimer?.invalidate()
    }

    private func startTimers() {
        // Age-based rules are checked on a timer, not on events.
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.runSweep(triggers: [.event, .daily])
        }
        // Picks up watch folders created after launch and re-reads edited rules.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.reloadConfigIfChanged()
            self?.watchers.reconcile(self?.watchDirectories() ?? [])
        }
    }

    // MARK: - Configuration

    private func loadConfig() {
        do {
            let config = try ConfigStore.loadOrCreate()
            let organizer = Organizer(config: config, dryRun: isDryRun)
            stateLock.lock()
            self.organizer = organizer
            stateLock.unlock()
            warnings = organizer.warnings()
            configError = nil
        } catch {
            // Keep the previous rules if there were any; never fall back to defaults and
            // start moving files the user did not ask for.
            configError = error.localizedDescription
            warnings = []
        }
        rulesStamp = modificationDate(of: Paths.rulesFile)
        watchers.reconcile(watchDirectories())
    }

    private func reloadConfigIfChanged() {
        let stamp = modificationDate(of: Paths.rulesFile)
        guard stamp != rulesStamp else { return }
        loadConfig()
        if configError == nil { runSweep(triggers: [.event]) }
    }

    /// The editor saved: apply the new rules now instead of waiting for the timer.
    private func rulesSaved() {
        loadConfig()
        if configError == nil { runSweep(triggers: [.event]) }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Work

    /// Debounces a directory's events, then organizes it on the work queue.
    private func scheduleScan(of directory: URL) {
        let key = Paths.canonical(directory)
        pendingScans[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScans[key] = nil
            self.organize(directory: directory, triggers: [.event])
        }
        pendingScans[key] = item
        work.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func runSweep(triggers: Set<Rule.Trigger>) {
        work.async { [weak self] in
            guard let self, let organizer = self.currentOrganizer() else { return }
            self.report(organizer.sweep(triggers: triggers))
        }
    }

    private func organize(directory: URL, triggers: Set<Rule.Trigger>) {
        guard let organizer = currentOrganizer() else { return }
        report(organizer.process(directory: directory, triggers: triggers))
    }

    private func watchDirectories() -> [URL] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return organizer?.directories(for: [.event]) ?? []
    }

    /// The organizer to use right now, or nil when paused or the rules are broken.
    private func currentOrganizer() -> Organizer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabled, let organizer else { return nil }
        organizer.dryRun = isDryRun
        return organizer
    }

    private func report(_ outcomes: [Organizer.Outcome]) {
        var entries: [LogEntry] = []
        for outcome in outcomes {
            guard let entry = outcome.logEntry else { continue }
            if outcome.kind == .failed {
                let key = "\(entry.source)|\(entry.detail ?? "")"
                guard loggedFailures.insert(key).inserted else { continue }
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return }
        log.append(entries)
        let summary = outcomes.last(where: { $0.logEntry != nil })?.summary
        DispatchQueue.main.async { [weak self] in
            self?.lastSummary = summary
            self?.logWindow.refreshIfVisible()
        }
    }

    // MARK: - Permissions

    /// Touches the protected folders so macOS shows its prompts, and explains what to do
    /// if access was denied.
    private func checkFolderAccess() {
        work.async { [weak self] in
            let roots = ["~/Desktop", "~/Downloads", "~/Documents"].map(Paths.expand)
            let denied = roots.filter { url in
                FileManager.default.fileExists(atPath: url.path)
                    && (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil
            }
            guard !denied.isEmpty else { return }
            DispatchQueue.main.async { self?.showAccessAlert(for: denied) }
        }
    }

    private func showAccessAlert(for denied: [URL]) {
        let alert = NSAlert()
        alert.messageText = "Tidy cannot read some folders"
        alert.informativeText = """
        Access was denied to: \(denied.map { Paths.abbreviate($0) }.joined(separator: ", ")).

        Grant Tidy access under Privacy & Security > Files and Folders, or add Tidy to \
        Full Disk Access, then reopen it.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state: String
        if configError != nil {
            state = "Rules file invalid"
        } else if !isEnabled {
            state = "Paused"
        } else if isDryRun {
            state = "Dry run"
        } else {
            state = "Active"
        }
        menu.addItem(disabled("Tidy \u{2014} \(state)"))
        if let summary = lastSummary {
            menu.addItem(disabled(truncate(summary, 64)))
        }
        if let configError {
            let item = NSMenuItem(title: truncate(configError, 64), action: #selector(editRules), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        for warning in warnings.prefix(3) {
            menu.addItem(disabled(truncate(warning, 64)))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Organizing", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = isEnabled ? .on : .off
        toggle.image = symbol(isEnabled ? "tray.full.fill" : "pause.circle")
        menu.addItem(toggle)

        let dry = NSMenuItem(title: "Dry Run", action: #selector(toggleDryRun), keyEquivalent: "")
        dry.target = self
        dry.state = isDryRun ? .on : .off
        dry.image = symbol("eye")
        menu.addItem(dry)

        let now = NSMenuItem(title: "Organize Now", action: #selector(organizeNow), keyEquivalent: "")
        now.target = self
        now.image = symbol("arrow.triangle.2.circlepath")
        menu.addItem(now)

        menu.addItem(.separator())

        let openLog = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        openLog.image = symbol("list.bullet.rectangle")
        menu.addItem(openLog)

        let rules = NSMenuItem(title: "Edit Rules", action: #selector(editRules), keyEquivalent: "")
        rules.target = self
        rules.image = symbol("slider.horizontal.3")
        menu.addItem(rules)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.image = symbol("power")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Tidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("xmark.circle")
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        updateIcon()
        if isEnabled { runSweep(triggers: [.event, .daily]) }
    }

    @objc private func toggleDryRun() {
        isDryRun.toggle()
        updateIcon()
    }

    @objc private func organizeNow() {
        reloadConfigIfChanged()
        runSweep(triggers: [.event, .daily])
    }

    @objc private func openLog() {
        logWindow.show()
    }

    @objc private func editRules() {
        rulesWindow.show()
    }

    /// Reopening Tidy from Finder, Spotlight or Raycast shows recent activity.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logWindow.show()
        return false
    }

    /// tidy://log and tidy://rules open the windows without going through the menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host ?? url.lastPathComponent {
            case "log": logWindow.show()
            case "rules": rulesWindow.show()
            default: break
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Presentation

    private func updateIcon() {
        let name: String
        let description: String
        if !isEnabled {
            name = "tray"
            description = "Tidy: paused"
        } else if isDryRun {
            name = "tray.full"
            description = "Tidy: dry run, no files are moved"
        } else {
            name = "tray.full.fill"
            description = "Tidy: organizing"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "\u{2026}"
    }
}
