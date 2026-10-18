import AppKit
import ClaudeMonitorCore

/// Carries out a JumpPlan: AppleScript for Terminal/iTerm2 tabs, plain activation otherwise.
/// Returns a message to show when it could not do exactly what was asked.
@MainActor
final class Jumper {
    private let log: AppLog
    /// errAEEventNotPermitted: the user denied Automation for that app.
    private static let notPermitted = -1743

    init(log: AppLog) { self.log = log }

    func jump(to session: Session) -> String? {
        switch JumpPlan.plan(for: session) {
        case .unavailable(let why):
            return why
        case .activate(let path):
            return activate(path: path)
        case .focusTab(let tty, let apps):
            return focusTab(tty: tty, in: apps)
        }
    }

    private func focusTab(tty: String, in apps: [TerminalApp]) -> String? {
        // Never launch a terminal just to search it.
        let running = apps.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty }
        guard !running.isEmpty else {
            return "\(apps.map(\.displayName).joined(separator: " / ")) is not running."
        }
        for app in running {
            var error: NSDictionary?
            let result = NSAppleScript(source: app.script(tty: tty))?.executeAndReturnError(&error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                log.log("jump: \(app.displayName) script failed (\(code)): \(error[NSAppleScript.errorMessage] ?? "")")
                activate(bundleId: app.bundleId)
                if code == Self.notPermitted {
                    return "Allow Claude Monitor to control \(app.displayName) in System Settings → "
                        + "Privacy & Security → Automation to jump to the exact tab."
                }
                return "Could not select the tab in \(app.displayName)."
            }
            if result?.stringValue == "found" { return nil }
        }
        activate(bundleId: running[0].bundleId)
        return "Its tab (\(tty)) was not found. It may have been closed."
    }

    @discardableResult
    private func activate(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return "\(url.lastPathComponent) was not found." }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [log] _, error in
            if let error { log.log("jump: could not open \(path): \(error)") }
        }
        return nil
    }

    private func activate(bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
    }
}
