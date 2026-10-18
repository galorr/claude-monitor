import AppKit
import ClaudeMonitorCore
import ClaudeMonitorMongo
import SwiftUI

@main
struct ClaudeMonitorApp: App {
    // App is created once; a plain constant avoids the @State/@StateObject macros,
    // whose plugins ship with Xcode but not with the Command Line Tools (D-009).
    private let model = AppModel()

    init() {
        // Menu-bar only, also when run unbundled via `swift run` (the .app sets LSUIElement).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            SessionListView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Bridges the engine (background queue) and the Mongo sync (actor) to SwiftUI (main actor).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var attentionCount = 0
    @Published private(set) var settings: MonitorSettings
    /// Session to scroll to and highlight (set when a notification is clicked).
    @Published var highlightedSessionId: String?
    /// View layout only: measured height of the session rows (no @State without Xcode, D-009).
    @Published var listHeight: CGFloat = 0
    @Published var showSettings = false
    @Published private(set) var mongoStatus = SyncEngine.Status.notConfigured
    /// The URI field in Settings; saved to the Keychain only on "Save".
    @Published var mongoURIDraft: String
    @Published private(set) var mongoTestResult: String?
    @Published private(set) var mongoTesting = false
    @Published private(set) var hookStatus = HookInstaller.Status.missing
    @Published private(set) var hookMessage: String?

    let paths: AppPaths
    let sync: SyncEngine
    private let engine: MonitorEngine
    private let log: AppLog
    private var notifier: Notifier?
    private var launchObserver: NSObjectProtocol?
    private var mongoURI: String?
    /// Keeps configure calls in order.
    private var configureTask: Task<Void, Never>?
    private let windows = WindowPresenter()
    private let hookInstaller = HookInstaller(paths: .standard(
        bundledScript: Bundle.main.url(forResource: "claude-monitor-hook", withExtension: "sh")))
    private static let settingsKey = "settings"
    private static let mongoAccount = "mongo-uri"

    init() {
        paths = AppPaths.standard()
        log = AppLog(url: paths.logFile)
        engine = MonitorEngine(paths: paths, log: log)
        settings = Self.loadSettings()
        mongoURI = Keychain.read(account: Self.mongoAccount)
        mongoURIDraft = mongoURI ?? ""

        let box = WeakBox<AppModel>()
        sync = SyncEngine(paths: paths, log: log) { status in
            Task { @MainActor in box.value?.mongoStatus = status }
        }
        box.value = self

        let notifier = Notifier(log: log) { [weak self] id in self?.reveal(sessionId: id) }
        self.notifier = notifier
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in notifier.start() }

        refreshHookStatus()
        applyMongoConfig()
        engine.start(settings: settings) { [weak self, sync] update in
            // Straight to the sync: Mongo upserts don't wait for the UI.
            Task { await sync.enqueue(update.changed) }
            Task { @MainActor in self?.apply(update) }
        }
    }

    var hasDoneSessions: Bool { sessions.contains { $0.state == .doneUnreviewed } }
    var isMongoConfigured: Bool { mongoURI != nil }

    func markReviewed(_ session: Session) {
        engine.markReviewed(session.id)
        notifier?.clear(sessionId: session.id)
    }

    func markAllDoneReviewed() {
        for s in sessions where s.state == .doneUnreviewed { notifier?.clear(sessionId: s.id) }
        engine.markAllDoneReviewed()
    }

    func updateSettings(_ change: (inout MonitorSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let retentionChanged = next.retentionDays != settings.retentionDays
        settings = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        engine.updateSettings(next)
        if retentionChanged { applyMongoConfig() }
    }

    // MARK: - Hooks

    func refreshHookStatus() {
        hookStatus = hookInstaller.status()
    }

    func installHooks() {
        runHookAction("Installed") { try $0.install() }
    }

    func uninstallHooks() {
        runHookAction("Removed") { try $0.uninstall() }
    }

    private func runHookAction(_ verb: String, _ action: (HookInstaller) throws -> HookInstaller.Outcome) {
        do {
            switch try action(hookInstaller) {
            case .unchanged:
                hookMessage = "Nothing to change."
            case .written(let backup):
                hookMessage = "\(verb). " + (backup.map { "Backup: \($0.path)" } ?? "")
                    + "\nRunning Claude sessions keep their old hooks until restarted."
            }
            log.log("hooks: \(verb.lowercased()) (\(hookInstaller.status().label))")
        } catch {
            hookMessage = "Failed: \(error)"
            log.log("hooks: \(verb.lowercased()) failed: \(error)")
        }
        refreshHookStatus()
    }

    // MARK: - Mongo

    func testMongo() {
        let uri = mongoURIDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        mongoTesting = true
        mongoTestResult = nil
        Task {
            var result: String
            do {
                let store = try await MongoStore.connect(uri: uri)
                let version = try await store.serverVersion()
                result = "OK: MongoDB \(version), database \(store.databaseName)"
                await store.close()
            } catch {
                result = "Failed: \(error)"
            }
            if !MongoURI.isLoopback(uri) { result += "\nWarning: not a 127.0.0.1 address." }
            mongoTestResult = result
            mongoTesting = false
        }
    }

    func saveMongoURI() {
        let uri = mongoURIDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.write(uri.isEmpty ? nil : uri, account: Self.mongoAccount)
        } catch {
            mongoTestResult = "Could not save to the Keychain: \(error)"
            return
        }
        mongoURI = uri.isEmpty ? nil : uri
        mongoURIDraft = uri
        mongoTestResult = uri.isEmpty ? "Removed. Mongo sync is off." : "Saved."
        applyMongoConfig()
    }

    func showHistory(_ session: Session) {
        let model = HistoryModel(session: session, sync: sync)
        windows.show("history-\(session.id)", title: "History: \(session.displayRepo)") {
            HistoryView(model: model)
        }
    }

    func showStats() {
        let model = StatsModel(sync: sync)
        windows.show("stats", title: "Claude Monitor Stats") { StatsView(model: model) }
    }

    private func applyMongoConfig() {
        let uri = mongoURI
        let days = settings.retentionDays
        var connect: SyncEngine.Connect?
        if let uri {
            connect = { try await MongoStore.connect(uri: uri) }
        }
        let previous = configureTask
        configureTask = Task { [sync] in
            await previous?.value
            await sync.configure(connect: connect, target: uri.map(MongoURI.targetId), retentionDays: days)
        }
    }

    // MARK: -

    private func apply(_ update: MonitorEngine.Update) {
        sessions = update.sessions
        attentionCount = update.attentionCount
        for s in update.notify { notifier?.post(s) }
        // A session that left a notifying state no longer needs its banner.
        for s in sessions where !s.state.needsAttention { notifier?.clear(sessionId: s.id) }
    }

    /// Notification click: open the session window with that session highlighted.
    private func reveal(sessionId: String) {
        highlightedSessionId = sessionId
        windows.show("sessions", title: "Claude Monitor", topRight: true, floating: true) {
            SessionListView(model: self)
        }
    }

    private static func loadSettings() -> MonitorSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(MonitorSettings.self, from: data) else { return MonitorSettings() }
        return s
    }
}

/// Lets a closure created during init reach the model once init has finished.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Regular windows: the session list opened by a notification click (SwiftUI cannot open
/// a MenuBarExtra window from code, decisions.md D-012), History and Stats.
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(_ key: String, title: String, topRight: Bool = false, floating: Bool = false,
                             content: () -> Content) {
        let window = windows[key] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
            w.title = title
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            if floating { w.level = .floating }
            w.center()
            windows[key] = w
            return w
        }()
        if topRight, let screen = NSScreen.main?.visibleFrame {
            // Under the menu bar, where the menu would have opened.
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 8))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// One session's event timeline from Mongo, a page at a time.
@MainActor
final class HistoryModel: ObservableObject {
    let session: Session
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var next: HistoryCursor?
    private let sync: SyncEngine
    static let pageSize = 50

    init(session: Session, sync: SyncEngine) {
        self.session = session
        self.sync = sync
        loadMore()
    }

    func loadMore() {
        guard !loading else { return }
        loading = true
        let cursor = next
        Task {
            do {
                let page = try await sync.history(sessionId: session.id, after: cursor, limit: Self.pageSize)
                items += page.items
                next = page.next
                hasMore = page.next != nil
                error = nil
            } catch {
                self.error = Self.describe(error)
            }
            loading = false
        }
    }

    static func describe(_ error: Error) -> String {
        if case SyncEngine.SyncError.notConnected = error { return "Mongo is not connected." }
        return "\(error)"
    }
}

@MainActor
final class StatsModel: ObservableObject {
    @Published var range = StatsRange.week {
        didSet { load() }
    }
    @Published private(set) var stats: SessionStats?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private let sync: SyncEngine

    init(sync: SyncEngine) {
        self.sync = sync
        load()
    }

    func load() {
        loading = true
        let range = range
        Task {
            do {
                stats = try await sync.stats(range)
                error = nil
            } catch {
                self.error = HistoryModel.describe(error)
            }
            loading = false
        }
    }
}
