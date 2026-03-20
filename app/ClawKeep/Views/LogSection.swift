import SwiftUI

struct LogSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("监控路径") {
                TextEditor(text: Binding(
                    get: { appState.config.log.watchPaths.joined(separator: "\n") },
                    set: { appState.config.log.watchPaths = splitLines($0) }
                ))
                .frame(height: 120)
            }

            TextField("崩溃归档目录", text: Binding(
                get: { appState.config.log.crashArchiveDir },
                set: { appState.config.log.crashArchiveDir = $0 }
            ))
            Stepper("崩溃抓取行数: \(appState.config.log.tailLinesOnCrash)", value: logTailBinding, in: 10...2000, step: 10)
            Stepper("归档保留天数: \(appState.config.log.maxArchiveDays)", value: archiveDaysBinding, in: 1...365)
            TextField("keepd 日志目录", text: Binding(
                get: { appState.config.daemon.logDir },
                set: { appState.config.daemon.logDir = $0 }
            ))
            Picker("日志级别", selection: Binding(
                get: { appState.config.daemon.logLevel },
                set: { appState.config.daemon.logLevel = $0 }
            )) {
                ForEach(["debug", "info", "warn", "error"], id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            Stepper("keepd 日志保留: \(appState.config.daemon.logRetainDays) 天", value: retainDaysBinding, in: 1...90)
            Button("保存配置", action: appState.saveConfig)
        }
        .formStyle(.grouped)
    }

    private var logTailBinding: Binding<Int> {
        Binding(
            get: { appState.config.log.tailLinesOnCrash },
            set: { appState.config.log.tailLinesOnCrash = $0 }
        )
    }

    private var archiveDaysBinding: Binding<Int> {
        Binding(
            get: { appState.config.log.maxArchiveDays },
            set: { appState.config.log.maxArchiveDays = $0 }
        )
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
