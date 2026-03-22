import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SettingsTab = .monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            healthBanner
            updateBanner
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
        .padding(28)
        .frame(minWidth: 920, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appState.config) { _, _ in
            appState.scheduleAutosave()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ClawKeep 设置")
                    .font(.system(size: 28, weight: .bold))
                Text("查看 OpenClaw 当前状态，调整自动修复和提醒方式。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.daemonRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appState.daemonRunning ? "后台服务运行中" : "后台服务未启动")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(appState.daemonRunning ? .green : .red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(appState.daemonRunning ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                .clipShape(Capsule())

                HStack(spacing: 10) {
                    if appState.canInstallAvailableUpdate {
                        Button("安装更新", action: appState.installAvailableUpdate)
                            .buttonStyle(.borderedProminent)
                    }
                    Button(appState.canCheckForUpdates ? "检查更新" : "检查更新中...") {
                        appState.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canCheckForUpdates)
                }
            }
        }
    }

    private var healthBanner: some View {
        let healthy = appState.isHealthy
        let background = healthy
            ? LinearGradient(colors: [Color.green.opacity(0.85), Color.mint.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color.orange.opacity(0.85), Color.yellow.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(appState.statusHeadline, systemImage: healthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if appState.isConnected {
                    Text(appState.status.statusText)
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }

            Text(appState.statusDetail)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 24) {
                statusFact("监控对象", value: appState.status.processName)
                statusFact("当前 PID", value: appState.status.pid > 0 ? "\(appState.status.pid)" : "等待中")
                statusFact("可用 Agent", value: appState.availableAgents.isEmpty ? "无" : "\(appState.availableAgents.count) 个")
            }
            .padding(.top, 4)
        }
        .foregroundStyle(healthy ? Color.white : Color.black.opacity(0.85))
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: (healthy ? Color.green : Color.orange).opacity(0.15), radius: 10, x: 0, y: 4)
    }

    private func statusFact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .opacity(0.85)
            Text(value)
                .font(.system(size: 16, weight: .bold))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selection == tab ? Color.white : Color.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                if selection == tab {
                                    Color.accentColor
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .matchedGeometryEffect(id: "tab", in: tabNamespace)
                                } else {
                                    Color(nsColor: .controlBackgroundColor).opacity(0.5)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @Namespace private var tabNamespace

    private var updateBanner: some View {
        SettingsCard("应用更新", description: "每天会自动拉一次远端更新配置，也可以手动立即检查。") {
            VStack(alignment: .leading, spacing: 12) {
                Text(appState.updateStatusTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(appState.updateStatusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if appState.canInstallAvailableUpdate {
                        Button("安装更新", action: appState.installAvailableUpdate)
                            .buttonStyle(.borderedProminent)
                    }
                    Button(appState.canCheckForUpdates ? "检查更新" : "检查更新中...") {
                        appState.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canCheckForUpdates)

                    Button("打开 Release 页面", action: appState.openLatestReleasePage)
                        .buttonStyle(.plain)
                }
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
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
    }
}

struct SettingsFooter: View {
    let action: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("所有更改已实时保存至本地配置")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) {
                Label("立即强制同步", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("s", modifiers: [.command])
        }
        .padding(.top, 8)
    }
}
