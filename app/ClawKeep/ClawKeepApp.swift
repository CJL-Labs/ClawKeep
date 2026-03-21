import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    static var sharedAppState: AppState?

    private var settingsWindowController: NSWindowController?

    override init() {
        super.init()
        Self.shared = self
    }

    @MainActor
    static func showDockAndActivate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func hideDock() {
        NSApp.setActivationPolicy(.accessory)
    }

    static func showSettingsWindow() {
        shared?.presentSettingsWindow()
    }

    func presentSettingsWindow() {
        guard let appState = Self.sharedAppState else { return }

        Self.showDockAndActivate()

        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClawKeep 设置"
        window.center()
        window.minSize = NSSize(width: 900, height: 700)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsView()
                .environmentObject(appState)
        )

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentSettingsWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindowController?.window else { return }
        settingsWindowController = nil
        Self.hideDock()
    }
}

@main
struct ClawKeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)

        DispatchQueue.main.async {
            AppDelegate.sharedAppState = state
            state.bootstrap()
            AppDelegate.showSettingsWindow()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            StatusBarView()
                .environmentObject(appState)
        } label: {
            LobsterMenuBarLabel(state: appState.mascotState, tick: appState.menuBarAnimationTick)
        }
        .menuBarExtraStyle(.window)
    }
}
