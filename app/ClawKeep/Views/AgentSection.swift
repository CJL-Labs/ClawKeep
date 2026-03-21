import SwiftUI

struct AgentSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPane {
            SettingsCard("优先修复工具", description: "ClawKeep 会先尝试这里选中的工具；如果它失败或超时，会自动 fallback 到其他已配置工具。第一次打开时会默认选中检测到的第一个。") {
                VStack(alignment: .leading, spacing: 12) {
                    if appState.availableAgents.isEmpty {
                        Text("暂时没有检测到 Claude Code 或 Codex。你可以先用下面的自定义修复命令。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("优先修复工具", selection: defaultAgentSelection) {
                            ForEach(appState.availableAgents) { agent in
                                Text(agent.displayName).tag(agent.name)
                            }
                            Text("自定义命令").tag("custom")
                        }
                        .pickerStyle(.radioGroup)

                        if let selectedAgent = selectedDetectedAgent {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("当前优先使用的命令")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(commandPreview(for: selectedAgent))
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("Claude Code 示例：\(claudeExample)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            SettingsCard("自定义修复命令", description: "如果你不用 Claude Code 或 Codex，可以在这里填自己的命令。你可以显式写 `{{prompt}}`；如果不写，ClawKeep 会自动把提示词作为最后一个参数追加。") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("命令路径（示例：/opt/homebrew/bin/claude）", text: customAgentPathBinding)
                    Text("这里填可执行文件本身的绝对路径，例如 `/opt/homebrew/bin/claude` 或 `/opt/homebrew/bin/codex`。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    TextField("命令参数（示例：--dangerously-skip-permissions -p {{prompt}}）", text: customAgentArgsBinding)
                    TextField("工作目录（命令执行时所在目录，例如：~/.openclaw/）", text: customAgentWorkingDirBinding)
                    Text("工作目录就是运行这条修复命令时所在的目录。Agent 会把这里当成当前项目目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    numericField(title: "超时时间（秒）", placeholder: "300", binding: customAgentTimeoutBinding)
                    Text("示例命令：\(claudeExample)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            SettingsCard("真正发送给模型的完整提示词", description: "下面这段内容会原样发给修复工具。你现在看到的，就是实际会发出去的修复提示词。") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("可用变量：`{{.ExitCode}}`、`{{.CrashTime}}`、`{{.WatchPaths}}`")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { appState.config.repair.promptTemplate },
                        set: { appState.config.repair.promptTemplate = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                }
            }

            SettingsFooter(action: appState.saveConfig)
        }
    }

    private var customAgent: AgentEntry {
        get {
            appState.config.agent.agents.first(where: { $0.name == "custom" }) ?? {
                var entry = AgentEntry()
                entry.name = "custom"
                entry.workingDir = ("~/.openclaw/" as NSString).expandingTildeInPath
                entry.timeoutSec = 300
                return entry
            }()
        }
        nonmutating set {
            if let index = appState.config.agent.agents.firstIndex(where: { $0.name == "custom" }) {
                appState.config.agent.agents[index] = newValue
            } else {
                appState.config.agent.agents.append(newValue)
            }
        }
    }

    private var customAgentPathBinding: Binding<String> {
        Binding(
            get: { customAgent.cliPath },
            set: {
                var entry = customAgent
                entry.cliPath = $0
                customAgent = entry
            }
        )
    }

    private var customAgentArgsBinding: Binding<String> {
        Binding(
            get: { customAgent.cliArgs.joined(separator: " ") },
            set: {
                var entry = customAgent
                entry.cliArgs = splitWords($0)
                customAgent = entry
            }
        )
    }

    private var customAgentWorkingDirBinding: Binding<String> {
        Binding(
            get: { customAgent.workingDir },
            set: {
                var entry = customAgent
                entry.workingDir = $0
                customAgent = entry
            }
        )
    }

    private var customAgentTimeoutBinding: Binding<String> {
        Binding(
            get: { String(customAgentTimeout) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                let value = Int(digits) ?? 0
                var entry = customAgent
                entry.timeoutSec = min(max(value, 30), 3600)
                customAgent = entry
            }
        )
    }

    private var customAgentTimeout: Int {
        max(customAgent.timeoutSec, 30)
    }

    private var defaultAgentSelection: Binding<String> {
        Binding(
            get: { appState.config.agent.defaultAgent.isEmpty ? appState.availableAgents.first?.name ?? "custom" : appState.config.agent.defaultAgent },
            set: { newValue in
                if newValue == "custom" {
                    selectCustomAgent()
                    return
                }
                if let detected = appState.availableAgents.first(where: { $0.name == newValue }) {
                    selectDetectedAgent(detected)
                } else {
                    appState.config.agent.defaultAgent = newValue
                }
            }
        )
    }

    private var selectedDetectedAgent: DetectedAgent? {
        appState.availableAgents.first(where: { $0.name == appState.config.agent.defaultAgent })
    }

    private var claudeExample: String {
        "claude --dangerously-skip-permissions -p {{prompt}}"
    }

    private func selectDetectedAgent(_ detected: DetectedAgent) {
        if let index = appState.config.agent.agents.firstIndex(where: { $0.name == detected.name }) {
            appState.config.agent.agents[index].cliPath = detected.cliPath
            appState.config.agent.agents[index].cliArgs = detected.cliArgs
            appState.config.agent.defaultAgent = appState.config.agent.agents[index].name
            return
        }

        var entry = AgentEntry()
        entry.name = detected.name
        entry.cliPath = detected.cliPath
        entry.cliArgs = detected.cliArgs
        entry.workingDir = ("~/.openclaw/" as NSString).expandingTildeInPath
        entry.timeoutSec = 300
        appState.config.agent.agents.append(entry)
        appState.config.agent.defaultAgent = detected.name
    }

    private func selectCustomAgent() {
        var entry = customAgent
        if entry.workingDir.isEmpty {
            entry.workingDir = ("~/.openclaw/" as NSString).expandingTildeInPath
        }
        customAgent = entry
        appState.config.agent.defaultAgent = "custom"
    }

    private func commandPreview(for agent: DetectedAgent) -> String {
        ([agent.cliPath] + agent.cliArgs).joined(separator: " ")
    }

    private func splitWords(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
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
}
