import SwiftUI

struct NotifySection: View {
    @EnvironmentObject private var appState: AppState
    private let eventItems: [(id: String, title: String)] = [
        ("crash", "发现 OpenClaw 异常时提醒"),
        ("repair_start", "开始自动修复时提醒"),
        ("repair_success", "修复成功时提醒"),
        ("repair_fail", "修复失败时提醒"),
        ("restart", "重新拉起 OpenClaw 时提醒"),
        ("agent_timeout", "修复工具超时时提醒")
    ]

    var body: some View {
        SettingsPane {
            SettingsCard("提醒阶段", description: "下面这些阶段默认都会勾上。你也可以按自己的习惯取消其中一部分。") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(eventItems, id: \.id) { item in
                        Toggle(item.title, isOn: notifyBinding(for: item.id))
                    }
                }
            }

            SettingsCard("飞书提醒", description: "把飞书群机器人的 Webhook 地址贴进来就可以了。异常、修复开始、修复结果这些提醒会默认全部发送。") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用飞书提醒", isOn: Binding(
                        get: { appState.config.notify.feishu.enabled },
                        set: { appState.config.notify.feishu.enabled = $0 }
                    ))
                    TextField("飞书 Webhook", text: Binding(
                        get: { appState.config.notify.feishu.webhookURL },
                        set: { appState.config.notify.feishu.webhookURL = $0 }
                    ))
                    TextField("飞书 Secret（如果机器人启用了签名）", text: Binding(
                        get: { appState.config.notify.feishu.secret },
                        set: { appState.config.notify.feishu.secret = $0 }
                    ))
                    Button("测试飞书") { appState.testNotify(channel: "feishu") }
                }
            }

            SettingsCard("Bark 提醒", description: "默认服务地址是官方地址。你只需要填自己的 Device Key；如果你用自建 Bark，也可以改服务地址。") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用 Bark 提醒", isOn: Binding(
                        get: { appState.config.notify.bark.enabled },
                        set: { appState.config.notify.bark.enabled = $0 }
                    ))
                    TextField("Bark 服务地址", text: Binding(
                        get: { appState.config.notify.bark.serverURL },
                        set: { appState.config.notify.bark.serverURL = $0 }
                    ))
                    TextField("Device Key", text: Binding(
                        get: { appState.config.notify.bark.deviceKey },
                        set: { appState.config.notify.bark.deviceKey = $0 }
                    ))
                    Text("示例：\(barkExampleURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("测试 Bark") { appState.testNotify(channel: "bark") }
                }
            }

            SettingsFooter(action: appState.saveConfig)
        }
    }

    private var barkExampleURL: String {
        let server = appState.config.notify.bark.serverURL.isEmpty ? "https://api.day.app" : appState.config.notify.bark.serverURL
        let key = appState.config.notify.bark.deviceKey.isEmpty ? "<你的DeviceKey>" : appState.config.notify.bark.deviceKey
        return "\(server)/\(key)/ClawKeep/OpenClaw%20%E7%8A%B6%E6%80%81%E6%AD%A3%E5%B8%B8"
    }

    private func notifyBinding(for event: String) -> Binding<Bool> {
        Binding(
            get: { appState.config.notify.notifyOn.contains(event) },
            set: { enabled in
                if enabled {
                    if !appState.config.notify.notifyOn.contains(event) {
                        appState.config.notify.notifyOn.append(event)
                    }
                } else {
                    appState.config.notify.notifyOn.removeAll { $0 == event }
                }
            }
        )
    }
}
