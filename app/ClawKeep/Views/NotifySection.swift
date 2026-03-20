import SwiftUI

struct NotifySection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Toggle("飞书", isOn: Binding(
                get: { appState.config.notify.feishu.enabled },
                set: { appState.config.notify.feishu.enabled = $0 }
            ))
            TextField("飞书 Webhook", text: Binding(
                get: { appState.config.notify.feishu.webhookURL },
                set: { appState.config.notify.feishu.webhookURL = $0 }
            ))
            Toggle("Bark", isOn: Binding(
                get: { appState.config.notify.bark.enabled },
                set: { appState.config.notify.bark.enabled = $0 }
            ))
            TextField("Bark Server", text: Binding(
                get: { appState.config.notify.bark.serverURL },
                set: { appState.config.notify.bark.serverURL = $0 }
            ))
            Toggle("SMTP", isOn: Binding(
                get: { appState.config.notify.smtp.enabled },
                set: { appState.config.notify.smtp.enabled = $0 }
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
}
