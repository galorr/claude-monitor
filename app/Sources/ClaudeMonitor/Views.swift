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
                                           highlighted: session.id == model.highlightedSessionId) {
                                    model.markReviewed(session)
                                }
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
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
        }
        .frame(width: 420)
        .onDisappear { model.highlightedSessionId = nil }
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
