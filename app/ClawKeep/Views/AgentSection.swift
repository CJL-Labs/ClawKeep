import SwiftUI

struct AgentSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            TextField("默认 Agent", text: Binding(
                get: { appState.config.agent.defaultAgent },
                set: { appState.config.agent.defaultAgent = $0 }
            ))
            Toggle("自动修复", isOn: Binding(
                get: { appState.config.repair.autoRepair },
                set: { appState.config.repair.autoRepair = $0 }
            ))
            Toggle("自动重启", isOn: Binding(
                get: { appState.config.repair.autoRestart },
                set: { appState.config.repair.autoRestart = $0 }
            ))
            TextField("重启命令", text: Binding(
                get: { appState.config.repair.restartCommand },
                set: { appState.config.repair.restartCommand = $0 }
            ))
            TextEditor(text: Binding(
                get: { appState.config.repair.promptTemplate },
                set: { appState.config.repair.promptTemplate = $0 }
            ))
            .frame(height: 220)
            Button("保存配置", action: appState.saveConfig)
        }
        .formStyle(.grouped)
    }
}
