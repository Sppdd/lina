import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: GhostEngine
    @ObservedObject var palette: PaletteController
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stats = WritingStats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Wordmark(size: 20)
                Spacer()
                StatusPill(status: engine.status, app: engine.currentApp.name)
            }
            .padding(.horizontal, 4)

            callout

            todayCard

            VStack(spacing: 0) {
                ToggleRow(title: "Suggestions", subtitle: "Ghost text when you pause", isOn: $settings.enabled)
                if !engine.currentApp.bundleID.isEmpty {
                    Divider().padding(.leading, 12)
                    ToggleRow(title: "Pause in \(engine.currentApp.name)", subtitle: nil, isOn: Binding(
                        get: { settings.disabledApps.contains(engine.currentApp.bundleID) },
                        set: { on in
                            if on { settings.disabledApps.insert(engine.currentApp.bundleID) }
                            else { settings.disabledApps.remove(engine.currentApp.bundleID) }
                        }))
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))

            VStack(spacing: 2) {
                MenuRow(title: "Ask Lina…", symbol: "pencil.and.scribble", shortcut: settings.hotKey.title) {
                    closeMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { palette.open() }
                }
                MenuRow(title: "Open Desk", symbol: "doc.richtext", shortcut: nil) {
                    closeMenu()
                    WindowOpener.shared.open("desk")
                }
                MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                    closeMenu()
                    WindowOpener.shared.settings()
                }
                Divider().padding(.vertical, 4)
                MenuRow(title: "Quit Lina", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func closeMenu() {
        NSApp.keyWindow?.close()
    }

    @ViewBuilder private var callout: some View {
        switch engine.status {
        case .needsPermission:
            Callout(symbol: "hand.raised.fill", tint: .orange,
                    title: "Lina needs Accessibility access",
                    message: "So it can read the text field you're writing in and show suggestions at your cursor.",
                    action: ("Grant Access", { AX.requestTrust(); AX.openAccessibilitySettings() }))
        case .needsModel:
            Callout(symbol: "key.fill", tint: Theme.ink,
                    title: "Connect a model",
                    message: "Add your Nebius API key, or point Lina at a model running on this Mac.",
                    action: ("Open Settings", { closeMenu(); WindowOpener.shared.settings() }))
        case let .error(message):
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                    title: "Lina couldn't reach the model",
                    message: message,
                    action: ("Try Again", { engine.clearError() }))
        default:
            EmptyView()
        }
    }

    private var todayCard: some View {
        let today = stats.today
        let goal = max(1, settings.dailyGoal)
        let week = stats.lastDays(7)
        let peak = max(goal, week.map(\.words).max() ?? 1)
        return HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: Double(today.words) / Double(goal), lineWidth: 5)
                Image(systemName: today.words >= goal ? "checkmark" : "pencil")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(today.words)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("of \(goal) words today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if stats.streak > 1 {
                    Text("\(stats.streak)-day streak")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink)
                } else if today.accepted > 0 {
                    Text("\(today.accepted) suggestion\(today.accepted == 1 ? "" : "s") kept")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(week.enumerated()), id: \.offset) { i, day in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(i == week.count - 1 ? Theme.ink : Theme.ink.opacity(0.3))
                            .frame(width: 6, height: max(3, 36 * CGFloat(day.words) / CGFloat(peak)))
                        Text(day.label).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 50, alignment: .bottom)
            .accessibilityLabel("Words written in the last seven days")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.paperEdge, lineWidth: 0.5))
    }
}

struct StatusPill: View {
    let status: GhostEngine.Status
    let app: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.05)))
    }

    private var color: Color {
        switch status {
        case .listening, .showing: .green
        case .thinking: Theme.ink
        case .paused: .secondary
        case .needsPermission, .needsModel, .error: .orange
        }
    }

    private var label: String {
        switch status {
        case .listening: app.isEmpty ? "Reading along" : "Reading along"
        case .thinking: "Thinking…"
        case .showing: "Suggesting"
        case .paused: "Paused"
        case .needsPermission: "Needs access"
        case .needsModel: "No model"
        case .error: "Offline"
        }
    }
}

struct Callout: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let action: (String, () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(action.0, action: action.1).buttonStyle(InkButtonStyle()).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct MenuRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(hover ? .white : .secondary)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(hover ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundStyle(hover ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Theme.ink : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
