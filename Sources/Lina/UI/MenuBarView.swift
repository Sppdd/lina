import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: LinaEngine
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var history = History.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LinaFace(mood: engine.mood, head: true, animated: true)
                    .frame(width: 40, height: 41)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lina").font(Theme.serif(18, weight: .semibold))
                    Text(statusLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(engine.mood == .worried ? Mood.worried.hair : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Circle().fill(engine.mood.hair).frame(width: 8, height: 8).help(engine.mood.meaning)
            }
            .padding(.horizontal, 4)

            callout

            VStack(spacing: 0) {
                ToggleRow(title: "Lina is on", subtitle: "Answers /lina in any app", isOn: $settings.enabled)
                Divider().padding(.leading, 12)
                ToggleRow(title: "Check sentences", subtitle: "Typos and grammar when you type a dot", isOn: $settings.checkSentences)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("TYPE IN ANY APP").font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                FlowLayout(spacing: 6) {
                    ForEach(["/lina.", "/lina fix.", "/lina rewrite.", "/lina model", "/lina <question>,"], id: \.self) { c in
                        Text(c)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.ink.opacity(0.08)))
                    }
                }
            }
            .padding(.horizontal, 4)

            if let last = history.items.first {
                Button { open(.saved) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: last.kind.symbol).foregroundStyle(Theme.ink).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Last: \(last.prompt)").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text(last.result).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.paperEdge, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 2) {
                MenuRow(title: "Open Lina", symbol: "face.smiling", shortcut: nil) { open(.meet) }
                MenuRow(title: "Saved", symbol: "tray.full", shortcut: nil) { open(.saved) }
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

    private var statusLine: String {
        let app = engine.currentApp.name
        switch engine.status {
        case .ready: return app.isEmpty ? "Ready when you are" : "Ready in \(app)"
        case .listening: return "Listening… end with . , ? or Return"
        case let .working(label): return label
        case .waiting: return "Waiting for your ⌘ choice"
        case .off: return "Off"
        case .paused: return "Paused in \(app)"
        case .needsPermission: return "Needs Accessibility access"
        case .needsModel: return "Needs an API key"
        case let .error(message): return message
        }
    }

    private func open(_ section: HomeSection) {
        closeMenu()
        HomeNavigation.shared.section = section
        WindowOpener.shared.open("home")
    }

    private func closeMenu() {
        NSApp.keyWindow?.close()
    }

    @ViewBuilder private var callout: some View {
        switch engine.status {
        case .needsPermission:
            Callout(symbol: "hand.raised.fill", tint: Mood.worried.hair,
                    title: "Lina needs Accessibility access",
                    message: "So she can read the line you're typing and show her card under it.",
                    action: ("Grant Access", { AX.grantAccess() }))
        case .needsModel:
            Callout(symbol: "key.fill", tint: Theme.ink,
                    title: "Connect a model",
                    message: "Add a Nebius API key (and a Gemini key for web search), or use a model on this Mac.",
                    action: ("Open Settings", { closeMenu(); WindowOpener.shared.settings() }))
        case let .error(message):
            Callout(symbol: "exclamationmark.triangle.fill", tint: Mood.worried.hair,
                    title: "Something went wrong",
                    message: message,
                    action: ("Try Again", { engine.dismiss() }))
        default:
            EmptyView()
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
