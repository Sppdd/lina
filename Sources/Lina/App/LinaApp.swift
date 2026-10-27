import SwiftUI
import AppKit

@main
struct LinaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: delegate.engine, palette: delegate.palette)
        } label: {
            MenuBarLabel(engine: delegate.engine)
        }
        .menuBarExtraStyle(.window)

        Window("Desk", id: "desk") {
            DeskView(openPalette: { delegate.palette.open() })
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Page") {
                    DeskStore.shared.create()
                    WindowOpener.shared.open("desk")
                }
                .keyboardShortcut("n")
            }
        }

        Window("Welcome to Lina", id: "welcome") {
            OnboardingView(engine: delegate.engine)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(engine: delegate.engine)
        }
    }
}

/// Lets AppKit code (hotkeys, menus) open SwiftUI windows.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    func open(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        openWindow?(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    func settings() {
        NSApp.setActivationPolicy(.regular)
        openSettings?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu bar icon. It is always on screen, so it's also where we capture the window actions.
struct MenuBarLabel: View {
    @ObservedObject var engine: GhostEngine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                WindowOpener.shared.openWindow = openWindow
                WindowOpener.shared.openSettings = openSettings
                if !AppSettings.shared.hasOnboarded {
                    DispatchQueue.main.async { WindowOpener.shared.open("welcome") }
                }
            }
    }

    private var symbol: String {
        switch engine.status {
        case .paused: "pencil.slash"
        case .needsPermission, .needsModel, .error: "exclamationmark.bubble"
        case .thinking: "ellipsis.bubble"
        default: "pencil.and.scribble"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = GhostEngine()
    let palette = PaletteController()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = Bundle.main.image(forResource: "AppIcon") { NSApp.applicationIconImage = icon }

        palette.deskTargetProvider = { DeskRegistry.shared.activeTarget }
        HotKeyCenter.shared.handler = { [weak self] in self?.palette.toggle() }
        HotKeyCenter.shared.register(AppSettings.shared.hotKey)

        engine.start()
        // Accessibility can be granted at any time; pick it up without a relaunch.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.refreshStatus() }
        }

        // Return to a menu-bar-only app when the last window closes.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                let visible = NSApp.windows.contains {
                    $0.isVisible && !($0 is NSPanel) && $0.className != "NSStatusBarWindow"
                        && $0.styleMask.contains(.titled)
                }
                if !visible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.shared.open("desk") }
        return true
    }
}
