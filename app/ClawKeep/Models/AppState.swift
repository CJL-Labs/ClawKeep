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
    let defaultNotifyEvents = ["crash", "repair_start", "repair_success", "repair_fail", "agent_timeout"]

    private let daemonManager = DaemonManager()
    private let ipcClient = IPCClient()
    private var didStart = false
    private var connectionTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var statusPollTask: Task<Void, Never>?
    private var suppressAutosave = false
    private var lastPersistedConfig: AppConfig?
    private var isPersistingConfig = false
    private var pendingConfigSave = false

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
                applyConfigFromDaemon(try await ipcClient.fetchConfig())
                status = try await ipcClient.fetchStatus()
                isConnected = true
                errorMessage = ""
                backoffSeconds = 1
                startStatusPolling()

                try await ipcClient.subscribeStatus { [weak self] newStatus in
                    await MainActor.run {
                        self?.status = newStatus
                    }
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                statusPollTask?.cancel()
                statusPollTask = nil
                isConnected = false
                status.state = .unmonitored
                errorMessage = error.localizedDescription
                let delay = UInt64(backoffSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                backoffSeconds = min(backoffSeconds * 2, 30)
            }
        }
    }

    private func startStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let latestStatus = try await self.ipcClient.fetchStatus()
                    await MainActor.run {
                        self.status = latestStatus
                    }
                } catch {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func saveConfig() {
        scheduleAutosave(immediate: true)
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
                try await persistConfig()
                try await ipcClient.testNotify(channel: channel)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func restartGateway() {
        Task {
            do {
                let grace = max(config.monitor.exitGracePeriodSec, 1)
                try await ipcClient.enterMaintenance(durationSec: grace, reason: "应用内正在重启 OpenClaw Gateway")
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let manager = DaemonManager()
                        try manager.restartGateway()
                    }.value
                } catch {
                    try? await ipcClient.exitMaintenance()
                    throw error
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func pauseDetectionForMaintenance(minutes: Int = 5) {
        Task {
            do {
                try await ipcClient.enterMaintenance(
                    durationSec: minutes * 60,
                    reason: "已暂停异常检测，方便你手动升级或重启 OpenClaw"
                )
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
        if status.state == .maintenance {
            return "OpenClaw 正在维护或等待恢复"
        }
        if status.state == .crashDetected {
            return "检测到 OpenClaw 异常退出"
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
        if status.state == .crashDetected {
            return "\(status.processName) 刚刚异常退出，退出码 \(status.exitCode)。ClawKeep 正在准备修复。"
        }
        if status.state == .maintenance {
            return status.detail.isEmpty ? "ClawKeep 正在维护窗口内观察 OpenClaw 是否恢复。" : status.detail
        }
        if status.state == .repairing {
            return "检测到 \(status.processName) 异常，ClawKeep 正在自动修复。当前第 \(max(status.repairAttempts, 1)) 次尝试。"
        }
        if status.state == .collecting {
            return "ClawKeep 正在收集故障上下文，准备交给修复工具处理。"
        }
        if status.state == .exhausted {
            return "自动修复次数已用尽，请检查 OpenClaw 配置和日志后手动处理。"
        }
        if isHealthy {
            return "\(status.processName) 已连接，ClawKeep 正在持续守护它。"
        }
        if !errorMessage.isEmpty {
            return errorMessage
        }
        return "如果你已经打开了 OpenClaw，但这里仍然没有变绿，可以先检查设置里的启动命令和 Agent 配置。"
    }

    func scheduleAutosave(immediate: Bool = false) {
        guard !suppressAutosave else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.persistConfigIfNeeded()
        }
    }

    private func persistConfigIfNeeded() async {
        do {
            try await persistConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistConfig() async throws {
        guard isConnected else { return }
        pendingConfigSave = true
        guard !isPersistingConfig else { return }

        isPersistingConfig = true
        defer { isPersistingConfig = false }

        while pendingConfigSave {
            pendingConfigSave = false

            suppressAutosave = true
            normalizeConfigForDisplay()
            let snapshot = config
            suppressAutosave = false

            guard lastPersistedConfig != snapshot else { continue }

            _ = try await ipcClient.updateConfig(snapshot)
            lastPersistedConfig = snapshot
            if config != snapshot {
                pendingConfigSave = true
            }
        }
    }

    private func applyConfigFromDaemon(_ newConfig: AppConfig) {
        suppressAutosave = true
        config = newConfig
        normalizeConfigForDisplay()
        lastPersistedConfig = config
        suppressAutosave = false
    }

    private func normalizeConfigForDisplay() {
        config.repair.autoRepair = true
        config.monitor.host = "127.0.0.1"
        config.monitor.restartCooldownSec = 0
        if config.monitor.exitGracePeriodSec <= 0 {
            config.monitor.exitGracePeriodSec = 20
        }
        if config.repair.maxRepairAttempts <= 0 {
            config.repair.maxRepairAttempts = 3
        }
        config.notify.notifyOn = defaultNotifyEvents

        config.repair.promptTemplate = Self.defaultPromptTemplate
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
        }
    }
}
