import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Button("重启 Gateway", action: appState.restartGateway)
                .disabled(!appState.isConnected)
            Button("暂停异常检测 5 分钟") {
                appState.pauseDetectionForMaintenance()
            }
            .disabled(!appState.isConnected)
            Divider()
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
        .frame(width: 336)
    }

    private var header: some View {
        let mascotState = appState.mascotState
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LobsterStatusBadgeView(state: mascotState)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(mascotState.tint)
                            .frame(width: 9, height: 9)
                        Text(mascotState.title)
                            .font(.headline)
                    }
                    Text(mascotState.posture)
                        .font(.subheadline)
                    Text(mascotState.action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("关键词: \(mascotState.promptKeywords)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(appState.isHealthy ? "OpenClaw 正在运行" : appState.statusHeadline)
                .font(.subheadline.weight(.semibold))
            Text(appState.status.processName)
            Text("PID: \(appState.status.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastCrashTime = appState.status.lastCrashTime {
                Text("上次崩溃: \(lastCrashTime.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(appState.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("崩溃次数: \(appState.status.crashCount)")
                .font(.caption)
        }
    }
}
