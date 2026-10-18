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
                }
                if model.hasDoneSessions {
                    Button("Review all done") { model.markAllDoneReviewed() }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
            Divider()
            if model.sessions.isEmpty {
                Text("No sessions yet.\nEvents file: \(model.paths.eventsFile.path)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // A ScrollView in a MenuBarExtra window collapses to zero height unless
                // given one, so size it to the measured rows, capped.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sessions) { session in
                                SessionRow(session: session,
                                           highlighted: session.id == model.highlightedSessionId,
                                           showHistory: model.isMongoConfigured,
                                           onHistory: { model.showHistory(session) },
                                           onMarkReviewed: { model.markReviewed(session) })
                                .id(session.id)
                                Divider()
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
                Text(model.mongoStatus.label)
                    .font(.caption)
                    .foregroundStyle(mongoStatusColor)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
        }
        .frame(width: 420)
        .onDisappear { model.highlightedSessionId = nil }
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
            Toggle("Notifications", isOn: binding(\.notificationsEnabled))
            Stepper("Stale after \(model.settings.staleAfterMinutes) min of no events",
                    value: binding(\.staleAfterMinutes), in: 1...240)
            Stepper("Presumed dead after \(model.settings.deadAfterHours) h of no events",
                    value: binding(\.deadAfterHours), in: 1...72)
            Stepper("Hide ended sessions after \(model.settings.hideEndedAfterHours) h",
                    value: binding(\.hideEndedAfterHours), in: 1...168)
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
    }

    private func binding<T>(_ keyPath: WritableKeyPath<MonitorSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

struct SessionRow: View {
    let session: Session
    var highlighted = false
    var showHistory = false
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
                    Text(session.displayRepo).fontWeight(.semibold).lineLimit(1)
                    if let detail = branchDetail {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
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
