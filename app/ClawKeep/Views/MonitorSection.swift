import SwiftUI

struct MonitorSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            TextField("进程名", text: stringBinding(\.processName))
            TextField("PID 文件", text: stringBinding(\.pidFile))
            TextField("主机", text: stringBinding(\.host))
            Stepper("端口: \(appState.config.monitor.port)", value: intBinding(\.port), in: 1...65535)
            Toggle("启用 kqueue", isOn: boolBinding(\.enableKqueue))
            Toggle("启用 TCP 探活", isOn: boolBinding(\.enableTcpProbe))
            Stepper("TCP 超时: \(appState.config.monitor.tcpProbeTimeoutMs)ms", value: intBinding(\.tcpProbeTimeoutMs), in: 500...10000, step: 500)
            TextField("Health Command", text: stringBinding(\.healthCommand))
            Stepper("重启冷却: \(appState.config.monitor.restartCooldownSec)s", value: intBinding(\.restartCooldownSec), in: 0...600, step: 5)
            Stepper("最大重启次数: \(appState.config.monitor.maxRestartAttempts)", value: intBinding(\.maxRestartAttempts), in: 0...20)
            Button("保存配置", action: appState.saveConfig)
        }
        .formStyle(.grouped)
    }

    private func stringBinding(_ keyPath: WritableKeyPath<MonitorConfig, String>) -> Binding<String> {
        Binding(
            get: { appState.config.monitor[keyPath: keyPath] },
            set: { appState.config.monitor[keyPath: keyPath] = $0 }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<MonitorConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.config.monitor[keyPath: keyPath] },
            set: { appState.config.monitor[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<MonitorConfig, Int>) -> Binding<Int> {
        Binding(
            get: { appState.config.monitor[keyPath: keyPath] },
            set: { appState.config.monitor[keyPath: keyPath] = $0 }
        )
    }
}
