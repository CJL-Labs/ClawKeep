import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let defaultPromptTemplate = """
    OpenClaw Gateway 异常退出了。你需要先判断原因，然后直接完成修复并恢复服务。

    退出码: {{.ExitCode}}
    崩溃时间: {{.CrashTime}}

    建议优先检查这些日志位置:
    {{.WatchPaths}}

    目标：
    1. 找出最可能的根因。
    2. 自己去读取上面的日志文件，不要依赖我内嵌给你的日志摘录。
    3. 必须恢复 OpenClaw Gateway，并确认它重新启动且恢复监听。
    4. 不要只给出命令或改法；请直接执行必要的修复和恢复操作。
    5. 只在确实缺少关键信息时，明确说明还缺什么。
    """

    @Published var status = KeepStatusModel()
    @Published var config = AppConfig()
    @Published var daemonRunning = false
    @Published var isConnected = false
    @Published var errorMessage = ""
    @Published var availableAgents: [DetectedAgent] = []
    let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("claw-keep.sock")
    let configPath = ("~/.claw-keep/config.toml" as NSString).expandingTildeInPath
    let defaultNotifyEvents = ["crash", "repair_start", "repair_success", "repair_fail", "restart", "agent_timeout"]

    private let daemonManager = DaemonManager()
    private let ipcClient = IPCClient()
    private var didStart = false
    private var connectionTask: Task<Void, Never>?

    func bootstrap() {
        guard !didStart else { return }
        didStart = true

        Task {
            let configPath = self.configPath
            let socketPath = self.socketPath
            do {
                let startup = try await Task.detached(priority: .userInitiated) {
                    let manager = DaemonManager()
                    let runtime = manager.discoverRuntime()
                    try manager.ensureDefaultConfig(at: configPath, discovery: runtime)
                    try manager.start(configPath: configPath, socketPath: socketPath)
                    return runtime
                }.value

                availableAgents = startup.agents
                daemonRunning = true
                connectionTask?.cancel()
                connectionTask = Task { [weak self] in
                    await self?.maintainConnection()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func maintainConnection() async {
        var backoffSeconds = 1
        while !Task.isCancelled {
            do {
                try await ipcClient.connect(socketPath: socketPath)
                config = try await ipcClient.fetchConfig()
                normalizeConfigForDisplay()
                status = try await ipcClient.fetchStatus()
                isConnected = true
                errorMessage = ""
                backoffSeconds = 1

                try await ipcClient.subscribeStatus { [weak self] newStatus in
                    await MainActor.run {
                        self?.status = newStatus
                    }
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                isConnected = false
                status.state = .unmonitored
                errorMessage = error.localizedDescription
                let delay = UInt64(backoffSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                backoffSeconds = min(backoffSeconds * 2, 30)
            }
        }
    }

    func saveConfig() {
        normalizeConfigForDisplay()
        Task {
            do {
                config = try await ipcClient.updateConfig(config)
                normalizeConfigForDisplay()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func triggerRepair() {
        Task {
            do {
                try await ipcClient.triggerRepair()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func restart() {
        Task {
            do {
                try await ipcClient.restart()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resetMonitoring() {
        Task {
            do {
                try await ipcClient.resetMonitoring()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func testNotify(channel: String) {
        Task {
            do {
                normalizeConfigForDisplay()
                config = try await ipcClient.updateConfig(config)
                try await ipcClient.testNotify(channel: channel)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var isHealthy: Bool {
        daemonRunning && isConnected && status.state == .watching
    }

    var statusHeadline: String {
        if isHealthy {
            return "OpenClaw 正在正常运行"
        }
        if status.state == .repairing || status.state == .restarting || status.state == .collecting {
            return "ClawKeep 正在处理异常"
        }
        if !daemonRunning {
            return "后台守护还没有启动成功"
        }
        if !isConnected {
            return "正在连接后台守护"
        }
        if status.state == .exhausted || status.state == .crashDetected {
            return "OpenClaw 需要你留意一下"
        }
        return "OpenClaw 还没有开始稳定守护"
    }

    var statusDetail: String {
        if isHealthy {
            return "\(status.processName) 已连接，ClawKeep 正在持续守护它。"
        }
        if !errorMessage.isEmpty {
            return errorMessage
        }
        return "如果你已经打开了 OpenClaw，但这里仍然没有变绿，可以先检查设置里的启动命令和 Agent 配置。"
    }

    private func normalizeConfigForDisplay() {
        config.repair.autoRepair = true
        config.repair.autoRestart = true
        config.monitor.host = "127.0.0.1"
        config.monitor.restartCooldownSec = 0
        config.monitor.maxRestartAttempts = max(config.monitor.maxRestartAttempts, config.repair.maxRepairAttempts)
        config.repair.maxRepairAttempts = config.monitor.maxRestartAttempts
        config.notify.notifyOn = defaultNotifyEvents
        config.notify.bark.serverURL = config.notify.bark.serverURL.isEmpty ? "https://api.day.app" : config.notify.bark.serverURL

        config.repair.promptTemplate = Self.defaultPromptTemplate
        config.repair.restartCommand = "openclaw"
        if config.repair.restartArgs.isEmpty {
            config.repair.restartArgs = ["gateway"]
        }
        for detected in availableAgents {
            if let index = config.agent.agents.firstIndex(where: { $0.name == detected.name }) {
                config.agent.agents[index].cliPath = detected.cliPath
                config.agent.agents[index].cliArgs = detected.cliArgs
            } else {
                var entry = AgentEntry()
                entry.name = detected.name
                entry.cliPath = detected.cliPath
                entry.cliArgs = detected.cliArgs
                entry.workingDir = ("~/.openclaw/" as NSString).expandingTildeInPath
                entry.timeoutSec = 300
                config.agent.agents.append(entry)
            }
        }
        if let first = availableAgents.first {
            let validDefault = config.agent.agents.contains(where: { $0.name == config.agent.defaultAgent })
            if !validDefault {
                config.agent.defaultAgent = first.name
            }
        } else if config.agent.defaultAgent.isEmpty, let firstConfigured = config.agent.agents.first {
            config.agent.defaultAgent = firstConfigured.name
        }

        for index in config.agent.agents.indices {
            if config.agent.agents[index].workingDir.isEmpty {
                config.agent.agents[index].workingDir = ("~/.openclaw/" as NSString).expandingTildeInPath
            }
            if config.agent.agents[index].timeoutSec <= 0 {
                config.agent.agents[index].timeoutSec = 300
            }
            if !config.agent.agents[index].cliArgs.contains("{{prompt}}") {
                config.agent.agents[index].cliArgs.append("{{prompt}}")
            }
        }
    }
}
