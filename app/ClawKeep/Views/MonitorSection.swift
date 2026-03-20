import SwiftUI

struct MonitorSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            TextField("进程名", text: stringBinding(\.processName))
            TextField("PID 文件", text: stringBinding(\.pidFile))
            TextField("主机", text: stringBinding(\.host))
            Stepper("端口: \(appState.config.monitor.port)", value: int32Binding(\.port), in: 1...65535)
            Toggle("启用 kqueue", isOn: boolBinding(\.enableKqueue))
            Toggle("启用 TCP 探活", isOn: boolBinding(\.enableTcpProbe))
            Stepper("TCP 超时: \(appState.config.monitor.tcpProbeTimeoutMs)ms", value: int32Binding(\.tcpProbeTimeoutMs), in: 500...10000, step: 500)
            TextField("Health Command", text: stringBinding(\.healthCommand))
            Button("保存配置", action: appState.saveConfig)
        }
        .formStyle(.grouped)
    }

    private func stringBinding(_ keyPath: WritableKeyPath<Sentinel_V1_MonitorConfig, String>) -> Binding<String> {
        Binding(
            get: { appState.config.monitor[keyPath: keyPath] },
            set: { appState.config.monitor[keyPath: keyPath] = $0 }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<Sentinel_V1_MonitorConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.config.monitor[keyPath: keyPath] },
            set: { appState.config.monitor[keyPath: keyPath] = $0 }
        )
    }

    private func int32Binding(_ keyPath: WritableKeyPath<Sentinel_V1_MonitorConfig, Int32>) -> Binding<Int> {
        Binding(
            get: { Int(appState.config.monitor[keyPath: keyPath]) },
            set: { appState.config.monitor[keyPath: keyPath] = Int32($0) }
        )
    }
}
