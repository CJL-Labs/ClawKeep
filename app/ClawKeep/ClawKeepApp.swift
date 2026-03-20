import SwiftUI

@main
struct ClawKeepApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            StatusBarView()
                .environmentObject(appState)
        } label: {
            Label("ClawKeep", systemImage: appState.status.symbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        Window("Logs", id: "logs") {
            LogView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 420)
        }
    }
}
