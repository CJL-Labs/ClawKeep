import SwiftUI

struct NotifySection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("事件") {
                ForEach(["crash", "repair_start", "repair_success", "repair_fail", "restart", "agent_timeout"], id: \.self) { event in
                    Toggle(event, isOn: notifyOnBinding(event))
                }
            }

            Toggle("飞书", isOn: Binding(
                get: { appState.config.notify.feishu.enabled },
                set: { appState.config.notify.feishu.enabled = $0 }
            ))
            TextField("飞书 Webhook", text: Binding(
                get: { appState.config.notify.feishu.webhookURL },
                set: { appState.config.notify.feishu.webhookURL = $0 }
            ))
            TextField("飞书 Secret", text: Binding(
                get: { appState.config.notify.feishu.secret },
                set: { appState.config.notify.feishu.secret = $0 }
            ))
            Toggle("Bark", isOn: Binding(
                get: { appState.config.notify.bark.enabled },
                set: { appState.config.notify.bark.enabled = $0 }
            ))
            TextField("Bark Server", text: Binding(
                get: { appState.config.notify.bark.serverURL },
                set: { appState.config.notify.bark.serverURL = $0 }
            ))
            TextField("Bark Device Key", text: Binding(
                get: { appState.config.notify.bark.deviceKey },
                set: { appState.config.notify.bark.deviceKey = $0 }
            ))
            Toggle("SMTP", isOn: Binding(
                get: { appState.config.notify.smtp.enabled },
                set: { appState.config.notify.smtp.enabled = $0 }
            ))
            TextField("SMTP Host", text: Binding(
                get: { appState.config.notify.smtp.host },
                set: { appState.config.notify.smtp.host = $0 }
            ))
            Stepper("SMTP Port: \(appState.config.notify.smtp.port)", value: smtpPortBinding, in: 1...65535)
            TextField("SMTP Username", text: Binding(
                get: { appState.config.notify.smtp.username },
                set: { appState.config.notify.smtp.username = $0 }
            ))
            SecureField("SMTP Password", text: Binding(
                get: { appState.config.notify.smtp.password },
                set: { appState.config.notify.smtp.password = $0 }
            ))
            TextField("发件人", text: Binding(
                get: { appState.config.notify.smtp.from },
                set: { appState.config.notify.smtp.from = $0 }
            ))
            TextField("收件人（逗号分隔）", text: Binding(
                get: { appState.config.notify.smtp.to.joined(separator: ", ") },
                set: { appState.config.notify.smtp.to = splitList($0) }
            ))
            Toggle("SMTP TLS", isOn: Binding(
                get: { appState.config.notify.smtp.useTLS },
                set: { appState.config.notify.smtp.useTLS = $0 }
            ))
            HStack {
                Button("测试飞书") { appState.testNotify(channel: "feishu") }
                Button("测试 Bark") { appState.testNotify(channel: "bark") }
                Button("测试 SMTP") { appState.testNotify(channel: "smtp") }
                Button("保存配置", action: appState.saveConfig)
            }
        }
        .formStyle(.grouped)
    }

    private var smtpPortBinding: Binding<Int> {
        Binding(
            get: { appState.config.notify.smtp.port },
            set: { appState.config.notify.smtp.port = $0 }
        )
    }

    private func notifyOnBinding(_ event: String) -> Binding<Bool> {
        Binding(
            get: { appState.config.notify.notifyOn.contains(event) },
            set: { enabled in
                var current = appState.config.notify.notifyOn
                if enabled {
                    if !current.contains(event) {
                        current.append(event)
                    }
                } else {
                    current.removeAll { $0 == event }
                }
                appState.config.notify.notifyOn = current
            }
        )
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
