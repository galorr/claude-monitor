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
    /// View layout only: measured height of the session rows (no @State without Xcode, D-009).
    @Published var listHeight: CGFloat = 0
    let paths: AppPaths
    private let engine: MonitorEngine

    init() {
        paths = AppPaths.standard()
        engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile))
        engine.start { [weak self] sessions, count in
            Task { @MainActor in
                self?.sessions = sessions
                self?.attentionCount = count
            }
        }
    }

    func markReviewed(_ session: Session) {
        engine.markReviewed(session.id)
    }
}
