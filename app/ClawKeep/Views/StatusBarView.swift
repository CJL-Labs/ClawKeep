import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Button("手动重启", action: appState.restart)
            Button("触发修复", action: appState.triggerRepair)
            Button("重置监控", action: appState.resetMonitoring)
                .disabled(appState.status.state != .exhausted)
            Divider()
            Button("查看日志...") { openWindow(id: "logs") }
            SettingsLink {
                Text("设置...")
            }
            Divider()
            Button("退出 ClawKeep") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .task {
            appState.bootstrap()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.status.processName)
                .font(.headline)
            Text(appState.status.statusText)
            Text("PID: \(appState.status.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastCrashTime = appState.status.lastCrashTime {
                Text("上次崩溃: \(lastCrashTime.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !appState.status.detail.isEmpty {
                Text(appState.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("崩溃次数: \(appState.status.crashCount)")
                .font(.caption)
        }
    }
}
