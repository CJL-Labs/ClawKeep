import SwiftUI

struct LogSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPane {
            SettingsCard("要顺手收集哪些日志", description: "每行一个目录、文件或 glob。默认建议直接填关键日志文件，例如 `/tmp/openclaw/openclaw-*.log` 和 `~/.openclaw/logs/gateway.err.log`，避免把整个目录都盯上。") {
                TextEditor(text: Binding(
                    get: { appState.config.log.watchPaths.joined(separator: "\n") },
                    set: { appState.config.log.watchPaths = splitLines($0) }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
            }

            SettingsCard("ClawKeep 自己的运行日志", description: "如果你需要排查 ClawKeep 本身的问题，可以看这里。") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("日志保存目录")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("示例：~/.clawkeep/logs", text: Binding(
                            get: { appState.config.daemon.logDir },
                            set: { appState.config.daemon.logDir = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    }

                    Picker("日志详细程度", selection: Binding(
                        get: { appState.config.daemon.logLevel },
                        set: { appState.config.daemon.logLevel = $0 }
                    )) {
                        ForEach(["debug", "info", "warn", "error"], id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Stepper("日志保留时长：\(appState.config.daemon.logRetainDays) 天", value: retainDaysBinding, in: 1...90)
                        .font(.body)
                }
            }

            SettingsFooter(action: appState.saveConfig)
        }
    }
    private var retainDaysBinding: Binding<Int> {
        Binding(
            get: { appState.config.daemon.logRetainDays },
            set: { appState.config.daemon.logRetainDays = $0 }
        )
    }

    private func splitLines(_ value: String) -> [String] {
        value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
