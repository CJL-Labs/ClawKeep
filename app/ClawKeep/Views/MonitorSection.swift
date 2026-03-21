import SwiftUI

struct MonitorSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPane {
            SettingsCard("连接 OpenClaw", description: "ClawKeep 固定探测本机 OpenClaw Gateway：`127.0.0.1`。如果你的 Gateway 不在默认端口，可以在这里改端口。") {
                VStack(spacing: 12) {
                    numericField(title: "连接端口", placeholder: "18789", binding: intStringBinding(
                        get: { appState.config.monitor.port },
                        set: { appState.config.monitor.port = min(max($0, 1), 65535) }
                    ))
                    numericField(title: "检查超时（毫秒）", placeholder: "3000", binding: intStringBinding(
                        get: { appState.config.monitor.tcpProbeTimeoutMs },
                        set: { appState.config.monitor.tcpProbeTimeoutMs = min(max($0, 500), 10000) }
                    ))
                    numericField(title: "异常检测宽限期（秒）", placeholder: "20", binding: intStringBinding(
                        get: { appState.config.monitor.exitGracePeriodSec },
                        set: { appState.config.monitor.exitGracePeriodSec = min(max($0, 1), 300) }
                    ))
                    numericField(title: "最多修复尝试次数", placeholder: "3", binding: intStringBinding(
                        get: { appState.config.repair.maxRepairAttempts },
                        set: {
                            appState.config.repair.maxRepairAttempts = min(max($0, 1), 20)
                        }
                    ))
                    Text("默认 20 秒。手动升级、手动重启，以及应用内的重启操作，都算在这段宽限期里；如果在宽限期内恢复健康，就不会按异常处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("当前识别结果", description: "这里显示 ClawKeep 当前守护的对象和探测方式。") {
                VStack(alignment: .leading, spacing: 8) {
                    monitorFact("程序名", appState.config.monitor.processName)
                    monitorFact("PID 文件", appState.config.monitor.pidFile.isEmpty ? "未设置" : appState.config.monitor.pidFile)
                    monitorFact("探测地址", "\(appState.config.monitor.host):\(appState.config.monitor.port)")
                }
            }

            SettingsCard("维护操作", description: "应用内重启会自动进入维护窗口，不会直接触发异常修复。手动升级前也可以先暂停异常检测 5 分钟。") {
                HStack(spacing: 12) {
                    Button("重启 Gateway") {
                        appState.restartGateway()
                    }
                    Button("暂停异常检测 5 分钟") {
                        appState.pauseDetectionForMaintenance()
                    }
                }
            }

            SettingsFooter(action: appState.saveConfig)
        }
    }

    private func monitorFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numericField(title: String, placeholder: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func intStringBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<String> {
        Binding(
            get: { String(get()) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if let value = Int(digits) {
                    set(value)
                } else if digits.isEmpty {
                    set(0)
                }
            }
        )
    }
}
