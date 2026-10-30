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
            MenuBarView(engine: delegate.engine)
        } label: {
            MenuBarLabel(engine: delegate.engine)
        }
        .menuBarExtraStyle(.window)

        Window("Lina", id: "home") {
            HomeView(engine: delegate.engine)
        }
        .defaultSize(width: 1080, height: 740)

        Window("Welcome to Lina", id: "welcome") {
            OnboardingView(engine: delegate.engine)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Report a Problem", id: "report") {
            ReportView()
        }
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

/// Lina's face in the menu bar. Her hair color and expression follow what she's doing.
/// It is always on screen, so it's also where we capture the window actions.
struct MenuBarLabel: View {
    @ObservedObject var engine: LinaEngine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: LinaFaceImage.image(engine.mood))
            .accessibilityLabel("Lina, \(engine.mood.title.lowercased())")
            .onAppear {
                WindowOpener.shared.openWindow = openWindow
                WindowOpener.shared.openSettings = openSettings
                if !AppSettings.shared.hasOnboarded {
                    DispatchQueue.main.async { WindowOpener.shared.open("welcome") }
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = LinaEngine()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshots.runIfRequested(engine: engine)
        LiveTest.runIfRequested(engine: engine)
        NSApp.setActivationPolicy(.accessory)
        if let icon = Bundle.main.image(forResource: "AppIcon") { NSApp.applicationIconImage = icon }

        engine.onOpenSaved = {
            HomeNavigation.shared.section = .saved
            WindowOpener.shared.open("home")
        }
        HotKeyCenter.shared.handler = { [weak self] in self?.engine.askNow() }
        HotKeyCenter.shared.memoryHandler = { [weak self] in self?.engine.rememberSelection() }
        Clippings.shared.setEnabled(AppSettings.shared.gatherClippings)
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

    func applicationWillTerminate(_ notification: Notification) {
        History.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.shared.open("home") }
        return true
    }
}
