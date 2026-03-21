import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Button("手动重启", action: appState.restart)
            Button("触发修复", action: appState.triggerRepair)
            Button("重置监控", action: appState.resetMonitoring)
                .disabled(appState.status.state != .exhausted)
            Divider()
            Button("设置...") {
                AppDelegate.showSettingsWindow()
            }
            Divider()
            Button("退出 ClawKeep") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.isHealthy ? Color.green : (appState.isConnected ? Color.orange : Color.gray))
                    .frame(width: 10, height: 10)
                Text(appState.isHealthy ? "OpenClaw 正在运行" : appState.status.statusText)
                    .font(.headline)
            }
            Text(appState.status.processName)
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
