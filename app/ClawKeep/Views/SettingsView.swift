import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            MonitorSection()
                .environmentObject(appState)
                .tabItem { Text("监控") }
            AgentSection()
                .environmentObject(appState)
                .tabItem { Text("Agent") }
            NotifySection()
                .environmentObject(appState)
                .tabItem { Text("通知") }
        }
        .padding()
        .frame(width: 720, height: 520)
        .task {
            appState.bootstrap()
        }
    }
}
