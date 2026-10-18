import AppKit
import ClaudeMonitorCore
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

/// Bridges the engine (background queue) to SwiftUI (main actor).
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

    let paths: AppPaths
    private let engine: MonitorEngine
    private let log: AppLog
    private var notifier: Notifier?
    private var launchObserver: NSObjectProtocol?
    private static let settingsKey = "settings"

    init() {
        paths = AppPaths.standard()
        log = AppLog(url: paths.logFile)
        engine = MonitorEngine(paths: paths, log: log)
        settings = Self.loadSettings()

        let notifier = Notifier(log: log) { [weak self] id in self?.reveal(sessionId: id) }
        self.notifier = notifier
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in notifier.start() }

        engine.start(settings: settings) { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
    }

    var hasDoneSessions: Bool { sessions.contains { $0.state == .doneUnreviewed } }

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
        settings = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        engine.updateSettings(next)
    }

    private func apply(_ update: MonitorEngine.Update) {
        sessions = update.sessions
        attentionCount = update.attentionCount
        for s in update.notify { notifier?.post(s) }
        // A session that left a notifying state no longer needs its banner.
        for s in sessions where !s.state.needsAttention { notifier?.clear(sessionId: s.id) }
    }

    private let sessionWindow = SessionWindow()

    /// Notification click: open the session window with that session highlighted.
    private func reveal(sessionId: String) {
        highlightedSessionId = sessionId
        sessionWindow.show(model: self)
    }

    private static func loadSettings() -> MonitorSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(MonitorSettings.self, from: data) else { return MonitorSettings() }
        return s
    }
}

/// A regular window with the same session list, opened by a notification click.
/// SwiftUI cannot open a MenuBarExtra window from code, and a simulated click on the
/// status item does nothing (decisions.md D-012), so this is the reliable target.
@MainActor
final class SessionWindow {
    private var window: NSWindow?

    func show(model: AppModel) {
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        if let screen = NSScreen.main?.visibleFrame {
            // Top-right, under the menu bar: where the menu would have opened.
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 8))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SessionListView(model: model)))
        window.title = "Claude Monitor"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        return window
    }
}
