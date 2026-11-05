import AppKit
import ClaudeMonitorCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.attentionCount > 0 {
            Label("\(model.attentionCount)", systemImage: "sparkle")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "sparkle")
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SessionListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Monitor").font(.headline)
                Spacer()
                if model.attentionCount > 0 {
                    Text("\(model.attentionCount) need you").foregroundStyle(.secondary)
                } else if !model.sessions.isEmpty {
                    Text("Nothing needs you").foregroundStyle(.secondary)
                }
                if model.hasDoneSessions {
                    Button("Review all done") { model.markAllDoneReviewed() }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
            if let message = model.jumpMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            if model.sessions.isEmpty && model.tasks.isEmpty && model.artifacts.isEmpty && model.processTabs.isEmpty {
                EmptyState(hooksHealthy: model.hookStatus.isHealthy, eventsFile: model.paths.eventsFile.path)
            } else {
                // A ScrollView in a MenuBarExtra window collapses to zero height unless
                // given one, so size it to the measured rows, capped.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.listItems) { item in
                                switch item {
                                case .session(let session):
                                    row(session, inEpic: false)
                                case .epic(let group):
                                    EpicHeader(group: group, collapsed: model.isCollapsed(group.epicKey)) {
                                        model.toggleEpic(group.epicKey)
                                    }
                                    Divider()
                                    if !model.isCollapsed(group.epicKey) {
                                        ForEach(group.sessions) { row($0, inEpic: true) }
                                    }
                                }
                            }
                            if !model.tasks.isEmpty {
                                section(Self.backgroundSection, title: "Background",
                                        summary: Self.taskSummary(running: model.runningTaskCount, total: model.tasks.count),
                                        live: model.runningTaskCount > 0) {
                                    ForEach(model.tasks) { task in
                                        BackgroundJobRow(task: task) { model.open(task) }
                                        Divider()
                                    }
                                }
                            }
                            if !model.processTabs.isEmpty {
                                section(Self.processesSection, title: "Processes",
                                        summary: Self.processSummary(model.processTabs), live: false) {
                                    ForEach(model.processTabs) { tab in
                                        ProcessTabHeader(tab: tab) { model.open(tab) }
                                        ForEach(tab.groups) { group in
                                            ProcessRow(group: group, alertPercent: Double(model.settings.cpuAlertPercent)) {
                                                model.open(group)
                                            }
                                        }
                                        Divider()
                                    }
                                }
                            }
                            if !model.artifacts.isEmpty {
                                section(Self.artifactsSection, title: "Artifacts",
                                        summary: "\(model.artifacts.count)", live: false) {
                                    ForEach(model.artifacts) { artifact in
                                        ArtifactRow(artifact: artifact) { model.open(artifact) }
                                        Divider()
                                    }
                                }
                            }
                        }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        })
                    }
                    .frame(height: min(max(model.listHeight, 60), 520))
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        MainActor.assumeIsolated { model.listHeight = height }
                    }
                    .onAppear { scroll(proxy) }
                    .onChange(of: model.highlightedSessionId) { scroll(proxy) }
                }
            }
            Divider()
            if model.showSettings {
                SettingsPanel(model: model)
                Divider()
            }
            HStack {
                Button(model.showSettings ? "Hide settings" : "Settings…") { model.showSettings.toggle() }
                    .buttonStyle(.link)
                if model.isMongoConfigured {
                    Button("Stats…") { model.showStats() }
                        .buttonStyle(.link)
                }
                Spacer()
                if !model.hookStatus.isHealthy {
                    Button("Hooks need attention") { model.showSettings = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(model.mongoStatus.label)
                    .font(.caption)
                    .foregroundStyle(mongoStatusColor)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
        }
        .frame(width: 420)
        // The MenuBarExtra window's default glass turns a muddy, low-contrast grey when
        // the window is short over a light background; an opaque window colour keeps it legible.
        .background(Color(nsColor: .windowBackgroundColor))
        // …and that window never shrinks back after the content got shorter (D-017).
        .background(MenuBarWindowFitter())
        .onDisappear { model.highlightedSessionId = nil }
    }

    static let backgroundSection = "background"
    static let artifactsSection = "artifacts"
    static let processesSection = "processes"

    static func processSummary(_ tabs: [ProcessTab]) -> String {
        let cpu = tabs.reduce(0) { $0 + $1.cpuPercent }
        let leftovers = tabs.flatMap(\.groups).filter(\.isLeftover).count
        var parts = ["\(ProcessPolicy.format(percent: cpu)) CPU", "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"]
        if leftovers > 0 { parts.append("\(leftovers) left running") }
        return parts.joined(separator: " · ")
    }

    static func taskSummary(running: Int, total: Int) -> String {
        if running == 0 { return "\(total) finished" }
        return running == total ? "\(running) running" : "\(running) running, \(total - running) finished"
    }

    @ViewBuilder
    private func section<Rows: View>(_ key: String, title: String, summary: String, live: Bool,
                                     @ViewBuilder rows: () -> Rows) -> some View {
        SectionHeader(title: title, summary: summary, live: live, collapsed: model.isSectionCollapsed(key)) {
            model.toggleSection(key)
        }
        Divider()
        if !model.isSectionCollapsed(key) { rows() }
    }

    @ViewBuilder
    private func row(_ session: Session, inEpic: Bool) -> some View {
        SessionRow(session: session,
                   highlighted: session.id == model.highlightedSessionId,
                   inEpic: inEpic,
                   showHistory: model.isMongoConfigured,
                   cpuPercent: model.cpuBadge(for: session),
                   onOpen: { model.open(session) },
                   onHistory: { model.showHistory(session) },
                   onMarkReviewed: { model.markReviewed(session) })
            .id(session.id)
        Divider()
    }

    private var mongoStatusColor: Color {
        switch model.mongoStatus {
        case .offline: .orange
        case .connected(let backlog) where backlog > 0: .orange
        default: .secondary
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = model.highlightedSessionId else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.hookStatus.label)
                .foregroundStyle(model.hookStatus.isHealthy ? Color.secondary : Color.orange)
            HStack {
                Button(installLabel) { model.installHooks() }
                    .disabled(model.hookStatus.isHealthy)
                Button("Uninstall") { model.uninstallHooks() }
                    .disabled(model.hookStatus == .missing)
            }
            if let message = model.hookMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider().padding(.vertical, 4)
            HStack {
                Toggle("Shortcut to open the list", isOn: binding(\.hotkeyEnabled))
                Spacer()
                Button(model.recordingHotkey ? "Press keys…" : model.settings.hotkey.display) {
                    model.startRecordingHotkey()
                }
                .help("Click, then press the new shortcut")
            }
            if let message = model.hotkeyMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Notifications", isOn: binding(\.notificationsEnabled))
            Stepper("Stale after \(model.settings.staleAfterMinutes) min of no events",
                    value: binding(\.staleAfterMinutes), in: 1...240)
            Stepper("Presumed dead after \(model.settings.deadAfterHours) h of no events",
                    value: binding(\.deadAfterHours), in: 1...72)
            Stepper("Hide ended sessions after \(model.settings.hideEndedAfterHours) h",
                    value: binding(\.hideEndedAfterHours), in: 1...168)
            Divider().padding(.vertical, 4)
            Toggle("Process alerts", isOn: binding(\.processAlertsEnabled))
                .help("Shells and servers started by Claude that burn CPU, outlive their session or run for hours")
            Group {
                Stepper("CPU over \(model.settings.cpuAlertPercent)% (100% = one core)",
                        value: binding(\.cpuAlertPercent), in: 50...1000, step: 25)
                Stepper("…for \(model.settings.cpuAlertMinutes) min",
                        value: binding(\.cpuAlertMinutes), in: 1...60)
                Stepper("Shell running longer than \(model.settings.longShellHours) h",
                        value: binding(\.longShellHours), in: 1...72)
            }
            .disabled(!model.settings.processAlertsEnabled)
            Divider().padding(.vertical, 4)
            Text("Mongo URI (stored in the Keychain)").foregroundStyle(.secondary)
            TextField("mongodb://127.0.0.1:27017/<db>?directConnection=true", text: $model.mongoURIDraft)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            HStack {
                Button("Test") { model.testMongo() }
                    .disabled(model.mongoTesting || model.mongoURIDraft.isEmpty)
                Button("Save") { model.saveMongoURI() }
                if model.mongoTesting { ProgressView().controlSize(.small) }
            }
            if let result = model.mongoTestResult {
                Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Stepper("Keep Mongo history \(model.settings.retentionDays) days",
                    value: binding(\.retentionDays), in: 1...365)
        }
        .font(.callout)
        .padding(12)
        .onAppear { model.refreshHookStatus() }
    }

    private var installLabel: String {
        switch model.hookStatus {
        case .outdated: "Update hooks"
        case .manual: "Take over hooks"
        default: "Install hooks"
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<MonitorSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

struct SessionRow: View {
    let session: Session
    var highlighted = false
    /// Inside an epic group: lead with the task id, indent.
    var inEpic = false
    var showHistory = false
    /// CPU of the session's processes, when high enough to show (D-018).
    var cpuPercent: Double?
    var onOpen: () -> Void = {}
    var onHistory: () -> Void = {}
    let onMarkReviewed: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: sourceSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(session.source.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if inEpic, let task = session.taskId {
                        Text(task).fontWeight(.semibold).monospacedDigit()
                    }
                    Text(session.displayRepo).fontWeight(inEpic ? .regular : .semibold).lineLimit(1)
                    if !inEpic, let detail = branchDetail {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(session.lastEventAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text(session.state.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)
                    if let cpu = cpuPercent {
                        let busy = cpu >= ProcessPolicy.badgeMinPercent
                        Label("CPU \(ProcessPolicy.format(percent: cpu))", systemImage: busy ? "flame.fill" : "cpu")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(busy ? Color.purple : Color.secondary)
                            .help("CPU used right now in this session's terminal: the shells and servers "
                                  + "Claude started and anything you run there (claude itself not counted)")
                    }
                    Spacer()
                    if showHistory {
                        Button("History", action: onHistory)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if session.state.canMarkReviewed {
                        Button("Mark reviewed", action: onMarkReviewed)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                if let message = session.lastMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, inEpic ? 28 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(session.state.isEnded ? "This session has ended" : "Click to open its terminal")
    }

    private var branchDetail: String? {
        if let epic = session.epicKey, let task = session.taskId { return "\(epic) · \(task)" }
        return session.branch
    }

    private var sourceSymbol: String {
        switch session.source {
        case .terminal: "terminal"
        case .desktop: "macwindow"
        case .unknown: "questionmark.circle"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .needsPermission: .red
        case .waitingInput: .orange
        case .doneUnreviewed: .blue
        case .stale: .yellow
        case .presumedDead: .gray
        case .working: .green
        default: .secondary
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.session.displayRepo).font(.headline)
                Text([model.session.branch, String(model.session.id.prefix(8))].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.ts, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text(item.name).font(.callout)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        Divider()
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.secondary).padding(12)
                    } else if model.items.isEmpty && !model.loading {
                        Text("No events stored for this session yet.").foregroundStyle(.secondary).padding(12)
                    }
                    if model.hasMore {
                        Button("Load more") { model.loadMore() }
                            .disabled(model.loading)
                            .padding(12)
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

struct StatsView: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Range", selection: $model.range) {
                    ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.load() }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
            } else if let stats = model.stats {
                Text("\(stats.sessions) sessions").font(.headline)
                HStack(spacing: 24) {
                    metric("Median wait for permission", stats.medianPermissionWait)
                    metric("Median done → reviewed", stats.medianReviewDelay)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        buckets("By state", stats.byState)
                        buckets("By source", stats.bySource)
                        buckets("By repo", stats.byRepo)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 460)
    }

    private func metric(_ title: String, _ value: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(StatsMath.format) ?? "–").font(.title3.monospacedDigit())
        }
    }

    private func buckets(_ title: String, _ list: [Bucket]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if list.isEmpty { Text("–").foregroundStyle(.secondary) }
            ForEach(list) { b in
                HStack {
                    Text(b.key).lineLimit(1)
                    Spacer()
                    Text("\(b.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

struct EpicHeader: View {
    let group: EpicGroup
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(group.epicKey).fontWeight(.semibold)
            Text("\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if group.attentionCount > 0 {
                Text("\(group.attentionCount) need you")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}


/// Shown when there is nothing to list at all.
struct EmptyState: View {
    let hooksHealthy: Bool
    let eventsFile: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.title)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("No Claude sessions right now")
                .font(.callout.weight(.medium))
            Text(hooksHealthy
                 ? "Sessions show up here as soon as Claude Code runs."
                 : "Install the hooks in Settings to start tracking sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .help("Events file: \(eventsFile)")
    }
}

/// Collapsible header for the Background and Artifacts sections.
struct SectionHeader: View {
    let title: String
    let summary: String
    /// Something is still running: show a spinner.
    let live: Bool
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if live { ProgressView().controlSize(.mini) }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

struct BackgroundJobRow: View {
    let task: BackgroundJob
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(task.isRunning ? Color.green : Color.secondary)
                .frame(width: 16)
                .help(task.kind == .shell ? "Background command" : "Subagent")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(task.title).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                    if let repo = task.repo {
                        Text(repo).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(task.finishedAt ?? task.startedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(task.isRunning ? "Running" : "Finished")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(task.isRunning ? Color.green : Color.secondary)
                    if let detail = task.detail {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help("Click to open its session")
    }

    private var symbol: String {
        switch task.kind {
        case .shell: task.isRunning ? "play.circle" : "checkmark.circle"
        case .subagent: task.isRunning ? "person.2.circle" : "person.2.circle.fill"
        }
    }
}

struct ArtifactRow: View {
    let artifact: ArtifactRecord
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(artifact.displayTitle).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                    if let repo = artifact.repo {
                        Text(repo).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(artifact.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(artifact.url.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if artifact.publishCount > 1 {
                        Text("· \(artifact.publishCount) versions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help("Open in the browser")
    }
}

/// A shell or server a session started, with its CPU (D-018). Display only.
struct ProcessRow: View {
    let group: ProcessGroup
    /// The alert threshold: at or above it the CPU figure turns red.
    let alertPercent: Double
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(kindHelp)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.commandSummary)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(ProcessPolicy.format(percent: group.cpuPercent))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(cpuColor)
                }
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if group.isLeftover {
                        Text(group.orphaned ? "claude exited" : "session ended")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    if let hottest = group.hottest {
                        Text(hottest)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ProcessPolicy.format(duration: group.age(now: context.date)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(tooltip)
    }

    private var symbol: String {
        switch group.kind {
        case .shell: "terminal"
        case .mcp: "server.rack"
        case .other: "gearshape"
        case .terminal: "person.crop.square"
        }
    }

    private var kindLabel: String {
        switch group.kind {
        case .shell: "Claude shell"
        case .mcp: "MCP server"
        case .other: "started by claude"
        case .terminal: "yours"
        }
    }

    private var kindHelp: String {
        switch group.kind {
        case .shell: "Shell started by the Bash tool"
        case .mcp: "MCP server"
        case .other: "Process started by claude"
        case .terminal: "Started by you in this terminal, not by Claude"
        }
    }

    private var cpuColor: Color {
        if group.cpuPercent >= alertPercent { return .red }
        if group.cpuPercent >= 50 { return .orange }
        return .secondary
    }

    private var tooltip: String {
        var lines = [group.command]
        lines.append("pid \(group.pid) · \(group.processCount) process\(group.processCount == 1 ? "" : "es") · "
                     + "\(ProcessPolicy.format(duration: group.cpuSeconds)) CPU time")
        lines.append(group.sessionId == nil ? "Its session is unknown." : "Click to open its session.")
        return lines.joined(separator: "\n")
    }
}

/// One terminal tab in the Processes section: its sessions' repos, where it is, total CPU.
struct ProcessTabHeader: View {
    let tab: ProcessTab
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.tty == nil ? "macwindow" : "terminal.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(tab.title).fontWeight(.semibold).lineLimit(1)
            if let place = place {
                Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ProcessPolicy.format(percent: tab.cpuPercent))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tab.cpuPercent >= ProcessPolicy.badgeMinPercent ? Color.purple : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(tab.sessionId == nil ? "Its session is unknown" : "Total CPU in this tab. Click to open it.")
    }

    /// "Terminal · ttys003".
    private var place: String? {
        let parts = [tab.hostApp, tab.tty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
