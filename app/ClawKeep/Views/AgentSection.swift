import SwiftUI

struct AgentSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            if !appState.config.agent.agents.isEmpty {
                Picker("默认 Agent", selection: Binding(
                    get: { appState.config.agent.defaultAgent },
                    set: { appState.config.agent.defaultAgent = $0 }
                )) {
                    ForEach(appState.config.agent.agents, id: \.name) { agent in
                        Text(agent.name.isEmpty ? "未命名 Agent" : agent.name).tag(agent.name)
                    }
                }
            } else {
                TextField("默认 Agent", text: Binding(
                    get: { appState.config.agent.defaultAgent },
                    set: { appState.config.agent.defaultAgent = $0 }
                ))
            }

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
            TextField("重启参数（空格分隔）", text: Binding(
                get: { appState.config.repair.restartArgs.joined(separator: " ") },
                set: { appState.config.repair.restartArgs = splitWords($0) }
            ))
            Stepper("最大修复次数: \(appState.config.repair.maxRepairAttempts)", value: repairAttemptsBinding, in: 1...10)

            Section("Agent 列表") {
                ForEach(Array(appState.config.agent.agents.indices), id: \.self) { index in
                    AgentEditor(agent: agentBinding(index), onRemove: {
                        removeAgent(at: index)
                    })
                }
                Button("新增 Agent", action: addAgent)
            }

            Section("Prompt 模板") {
                TextEditor(text: Binding(
                    get: { appState.config.repair.promptTemplate },
                    set: { appState.config.repair.promptTemplate = $0 }
                ))
                .frame(height: 220)
            }

            Button("保存配置", action: appState.saveConfig)
        }
        .formStyle(.grouped)
    }

    private var repairAttemptsBinding: Binding<Int> {
        Binding(
            get: { appState.config.repair.maxRepairAttempts },
            set: { appState.config.repair.maxRepairAttempts = $0 }
        )
    }

    private func agentBinding(_ index: Int) -> Binding<AgentEntry> {
        Binding(
            get: { appState.config.agent.agents[index] },
            set: { appState.config.agent.agents[index] = $0 }
        )
    }

    private func addAgent() {
        var entry = AgentEntry()
        entry.name = "agent-\(appState.config.agent.agents.count + 1)"
        entry.timeoutSec = 300
        appState.config.agent.agents.append(entry)
        if appState.config.agent.defaultAgent.isEmpty {
            appState.config.agent.defaultAgent = entry.name
        }
    }

    private func removeAgent(at index: Int) {
        guard appState.config.agent.agents.indices.contains(index) else { return }
        let removed = appState.config.agent.agents[index]
        appState.config.agent.agents.remove(at: index)
        if appState.config.agent.defaultAgent == removed.name {
            appState.config.agent.defaultAgent = appState.config.agent.agents.first?.name ?? ""
        }
    }

    private func splitWords(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

private struct AgentEditor: View {
    @Binding var agent: AgentEntry
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("名称", text: $agent.name)
            TextField("CLI 路径", text: $agent.cliPath)
            TextField("参数（空格分隔）", text: Binding(
                get: { agent.cliArgs.joined(separator: " ") },
                set: { agent.cliArgs = $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            ))
            TextField("工作目录", text: $agent.workingDir)
            Stepper("超时: \(agent.timeoutSec)s", value: Binding(
                get: { agent.timeoutSec },
                set: { agent.timeoutSec = $0 }
            ), in: 1...3600, step: 30)
            TextEditor(text: Binding(
                get: { envText(agent.env) },
                set: { agent.env = parseEnv($0) }
            ))
            .frame(height: 90)
            Button("删除 Agent", role: .destructive, action: onRemove)
        }
        .padding(.vertical, 6)
    }
}

private func envText(_ env: [String: String]) -> String {
    env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
}

private func parseEnv(_ text: String) -> [String: String] {
    var env: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
    }
    return env
}
