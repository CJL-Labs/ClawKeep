import SwiftUI

struct NotifySection: View {
    @EnvironmentObject private var appState: AppState
    private let eventItems: [(id: String, title: String)] = [
        ("crash", "发现 OpenClaw 异常时提醒"),
        ("repair_start", "开始自动修复时提醒"),
        ("repair_success", "修复成功时提醒"),
        ("repair_fail", "修复失败时提醒"),
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

            SettingsCard("飞书提醒", description: "把飞书群里的自定义机器人 Webhook 地址贴进来就可以了。异常、修复开始、修复结果这些提醒会默认全部发送。") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("启用飞书提醒", isOn: Binding(
                        get: { appState.config.notify.feishu.enabled },
                        set: { appState.config.notify.feishu.enabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("飞书群自定义机器人 Webhook")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("https://open.feishu.cn/open-apis/bot/v2/hook/...", text: Binding(
                            get: { appState.config.notify.feishu.webhookURL },
                            set: {
                                appState.config.notify.feishu.webhookURL = $0
                                appState.scheduleAutosave()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    }
                    
                    Button {
                        appState.testNotify(channel: "feishu")
                    } label: {
                        Label("测试飞书发送", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsCard("Bark 提醒", description: "把 Bark App 里复制出来的完整推送 URL 贴进来，例如 https://api.day.app/你的Key。ClawKeep 会自动在后面拼上标题和正文。") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("启用 Bark 提醒", isOn: Binding(
                        get: { appState.config.notify.bark.enabled },
                        set: { appState.config.notify.bark.enabled = $0 }
                    ))
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bark 推送 URL")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("https://api.day.app/你的Key", text: Binding(
                            get: { appState.config.notify.bark.pushURL },
                            set: {
                                appState.config.notify.bark.pushURL = $0
                                appState.scheduleAutosave()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    }

                    Button {
                        appState.testNotify(channel: "bark")
                    } label: {
                        Label("测试 Bark 发送", systemImage: "bell.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsFooter(action: appState.saveConfig)
        }
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
