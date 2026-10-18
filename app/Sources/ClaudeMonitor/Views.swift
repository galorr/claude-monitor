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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sessions) { session in
                            SessionRow(session: session) { model.markReviewed(session) }
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
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
        }
        .frame(width: 420)
    }
}

struct SessionRow: View {
    let session: Session
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
        case .working: .green
        default: .secondary
        }
    }
}
