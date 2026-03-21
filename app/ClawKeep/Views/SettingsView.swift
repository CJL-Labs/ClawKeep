import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SettingsTab = .monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            healthBanner
            tabBar

            Group {
                switch selection {
                case .monitor:
                    MonitorSection()
                        .environmentObject(appState)
                case .agent:
                    AgentSection()
                        .environmentObject(appState)
                case .notify:
                    NotifySection()
                        .environmentObject(appState)
                case .log:
                    LogSection()
                        .environmentObject(appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 700)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onChange(of: appState.config) { _, _ in
            appState.scheduleAutosave()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ClawKeep 设置")
                    .font(.system(size: 26, weight: .semibold))
                Text("这里可以查看 OpenClaw 当前状态，也可以调整自动修复和提醒方式。关闭窗口后，状态栏会继续常驻。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Label(appState.daemonRunning ? "后台已启动" : "后台未启动", systemImage: appState.daemonRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(appState.daemonRunning ? .green : .red)
            }
        }
    }

    private var healthBanner: some View {
        let healthy = appState.isHealthy
        let background = healthy
            ? LinearGradient(colors: [Color.green.opacity(0.9), Color.mint.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color.orange.opacity(0.85), Color.yellow.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(appState.statusHeadline, systemImage: healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                if appState.isConnected {
                    Text(appState.status.statusText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            Text(appState.statusDetail)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                statusFact("监控对象", value: appState.status.processName)
                statusFact("当前 PID", value: appState.status.pid > 0 ? "\(appState.status.pid)" : "暂未拿到")
                statusFact("已检测到 Agent", value: appState.availableAgents.isEmpty ? "0 个" : "\(appState.availableAgents.count) 个")
            }
        }
        .foregroundStyle(healthy ? Color.white : Color.black.opacity(0.82))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statusFact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .opacity(0.82)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == tab ? Color.white : Color.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minWidth: 88)
                        .background(selection == tab ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum SettingsTab: CaseIterable, Identifiable {
    case monitor
    case agent
    case notify
    case log

    var id: Self { self }

    var title: String {
        switch self {
        case .monitor:
            "监控"
        case .agent:
            "修复Agent"
        case .notify:
            "通知"
        case .log:
            "日志"
        }
    }
}

struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let description: String?
    let content: Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

struct SettingsFooter: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Text("更改会自动保存")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("立即保存", action: action)
                .keyboardShortcut("s", modifiers: [.command])
        }
    }
}
