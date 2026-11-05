import Foundation

/// Samples the processes below each session's claude every few seconds and reports the
/// busy ones (decisions.md D-018). Separate from MonitorEngine: it reads the live process
/// table, not the events file, and keeps nothing on disk. State is confined to `queue`.
public final class ProcessMonitor: @unchecked Sendable {
    public struct Update: Sendable {
        /// Groups for the Processes section, busiest first.
        public var groups: [ProcessGroup]
        /// Current CPU per session id, for the row badge.
        public var cpuBySession: [String: Double]
        public var alerts: [ProcessAlert]
    }

    public typealias Listener = @Sendable (Update) -> Void

    private let queue = DispatchQueue(label: "claude-monitor.processes", qos: .utility)
    private let makeReader: @Sendable () -> ProcessTableReading
    private let now: @Sendable () -> Date
    private var reader: ProcessTableReading?
    private var sessions: [Session] = []
    private var settings = MonitorSettings()
    private var listener: Listener?
    private var timer: DispatchSourceTimer?
    private var rates = CpuRateTracker()
    private var alerts = ProcessAlertTracker()
    private var owners: [String: String] = [:]
    private var lastPublished: [ProcessGroup]?
    private var lastBySession: [String: Double] = [:]

    public init(reader: @escaping @Sendable () -> ProcessTableReading = { LibprocProcessTable() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        makeReader = reader
        self.now = now
    }

    public func start(settings: MonitorSettings, listener: @escaping Listener) {
        queue.async { [self] in
            self.settings = settings
            self.listener = listener
            reader = makeReader()
            tick()
            let t = DispatchSource.makeTimerSource(queue: queue)
            // The first rates need two samples: take the second one soon.
            t.schedule(deadline: .now() + 1, repeating: ProcessPolicy.interval, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func updateSessions(_ sessions: [Session]) {
        queue.async { [self] in self.sessions = sessions }
    }

    public func updateSettings(_ settings: MonitorSettings) {
        queue.async { [self] in self.settings = settings }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// One sample → one update. Internal so tests can drive it without the timer.
    func tick() {
        guard let reader else { return }
        let at = now()
        let roots = Set(sessions.compactMap { $0.claudePid.map(Int32.init) })
        let samples = reader.read(roots: roots)
        let current = rates.rates(samples, at: at)
        let groups = ProcessTree.groups(samples, sessions: sessions, rates: current, owners: &owners)
        let fired = alerts.evaluate(groups, now: at, settings: settings)
        let visible = ProcessPolicy.visible(groups, now: at, longShellHours: settings.longShellHours)
        let bySession = ProcessTree.cpuBySession(groups)
        // Quiet machine: no need to wake the UI every 5 s with the same empty list.
        if fired.isEmpty, visible.isEmpty, lastPublished?.isEmpty == true,
           bySession.values.allSatisfy({ $0 < ProcessPolicy.badgeMinPercent }),
           lastBySession.values.allSatisfy({ $0 < ProcessPolicy.badgeMinPercent }) { return }
        lastPublished = visible
        lastBySession = bySession
        listener?(Update(groups: visible, cpuBySession: bySession,
                         alerts: settings.processAlertsEnabled && settings.notificationsEnabled ? fired : []))
    }

    /// For tests: run `start` without the timer.
    func startForTesting(settings: MonitorSettings, listener: @escaping Listener) {
        queue.sync {
            self.settings = settings
            self.listener = listener
            reader = makeReader()
        }
    }

    func syncTick() { queue.sync { tick() } }
    func syncUpdateSessions(_ sessions: [Session]) { queue.sync { self.sessions = sessions } }
}
