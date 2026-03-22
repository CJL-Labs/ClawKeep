import Foundation
import SwiftUI

enum StatusMascotState: String, Equatable {
    case idle
    case busy
    case restarting
    case error
    case fixing
    case success
    case failed

    var title: String {
        switch self {
        case .idle:
            return "空闲（Idle）"
        case .busy:
            return "忙碌（Busy）"
        case .restarting:
            return "重启中（Restarting）"
        case .error:
            return "异常（Error）"
        case .fixing:
            return "开始修复（Fixing）"
        case .success:
            return "修复成功（Success）"
        case .failed:
            return "修复失败（Failed）"
        }
    }

    var posture: String {
        switch self {
        case .idle:
            return "放松 🙂"
        case .busy:
            return "专注 😐"
        case .restarting:
            return "迷糊 😵"
        case .error:
            return "惊讶 😳"
        case .fixing:
            return "认真 😤"
        case .success:
            return "开心 😄"
        case .failed:
            return "失落 😞"
        }
    }

    var action: String {
        switch self {
        case .idle:
            return "轻微呼吸 + 偶尔眨眼"
        case .busy:
            return "快速挥动钳子 / 操作"
        case .restarting:
            return "原地转圈 / loading"
        case .error:
            return "抖动 + 红色闪烁"
        case .fixing:
            return "拿工具敲敲打打"
        case .success:
            return "跳一下 + 举钳子"
        case .failed:
            return "坐下 / 低头不动"
        }
    }

    var promptKeywords: String {
        switch self {
        case .idle:
            return "calm, breathing, idle, minimal"
        case .busy:
            return "fast working, typing, busy"
        case .restarting:
            return "spinning, reboot, loading"
        case .error:
            return "alert, shaking, error"
        case .fixing:
            return "fixing, wrench, repair"
        case .success:
            return "celebrate, success, happy"
        case .failed:
            return "sad, tired, failed"
        }
    }

    var tint: Color {
        switch self {
        case .idle:
            return .green
        case .busy:
            return .blue
        case .restarting:
            return .orange
        case .error:
            return .red
        case .fixing:
            return .yellow
        case .success:
            return .mint
        case .failed:
            return .gray
        }
    }
}

enum ManualGatewayRestartPhase: Equatable {
    case idle
    case enteringMaintenance
    case sendingCommand
    case waitingForConfirmation

    var detail: String {
        switch self {
        case .idle:
            return ""
        case .enteringMaintenance:
            return "正在进入维护窗口，避免把这次手动重启误判成异常退出。"
        case .sendingCommand:
            return "已发送重启请求，正在等待 openclaw 返回。"
        case .waitingForConfirmation:
            return "重启命令已返回，正在确认 Gateway 进程是否真的退出并恢复。"
        }
    }
}

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
    @Published private(set) var menuBarAnimationTick = 0
    @Published private(set) var isAgentLoopBusy = false
    @Published private(set) var lastAgentLoopSignalAt: Date?
    @Published private(set) var manualGatewayRestartPhase: ManualGatewayRestartPhase = .idle
    let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("claw-keep.sock")
    let configPath = ("~/.claw-keep/config.toml" as NSString).expandingTildeInPath
    let defaultNotifyEvents = ["crash", "repair_start", "repair_success", "repair_fail", "agent_timeout"]

    private let daemonManager = DaemonManager()
    private let ipcClient = IPCClient()
    private var didStart = false
    private var connectionTask: Task<Void, Never>?
    private var menuBarAnimationTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var statusPollTask: Task<Void, Never>?
    private var activityPollTask: Task<Void, Never>?
    private var suppressAutosave = false
    private var lastPersistedConfig: AppConfig?
    private var isPersistingConfig = false
    private var pendingConfigSave = false
    private var recentRepairSuccessAt: Date?
    private var recentRepairFailureAt: Date?
    private var sessionIndexPaths: [String] = []
    private var sessionFileFingerprints: [String: UInt64] = [:]
    private var lastSessionPathRefreshAt: Date = .distantPast

    nonisolated private static let sessionPathRefreshIntervalSec: TimeInterval = 8
    nonisolated private static let sessionActiveWindowMs: Int64 = 7_000
    nonisolated private static let loopBusyHoldSeconds: TimeInterval = 2.8
    nonisolated private static let recentOutcomeDisplaySeconds: TimeInterval = 6
    nonisolated private static let sessionTailScanBytes: Int = 8_000
    nonisolated private static let busyPollIntervalNs: UInt64 = 350_000_000
    nonisolated private static let idlePollIntervalNs: UInt64 = 700_000_000

    func bootstrap() {
        guard !didStart else { return }
        didStart = true
        startMenuBarAnimation()
        startAgentLoopActivityPolling()

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
                applyStatusUpdate(try await ipcClient.fetchStatus())
                isConnected = true
                errorMessage = ""
                backoffSeconds = 1
                startStatusPolling()

                try await ipcClient.subscribeStatus { [weak self] newStatus in
                    await MainActor.run {
                        self?.applyStatusUpdate(newStatus)
                    }
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                statusPollTask?.cancel()
                statusPollTask = nil
                isConnected = false
                var disconnectedStatus = status
                disconnectedStatus.state = .unmonitored
                disconnectedStatus.detail = "正在等待重新连接 keepd。"
                applyStatusUpdate(disconnectedStatus)
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
                        self.applyStatusUpdate(latestStatus)
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
        guard !isRestartingGatewayManually else { return }
        Task {
            await performGatewayRestart()
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

    var isRestartingGatewayManually: Bool {
        manualGatewayRestartPhase != .idle
    }

    var mascotState: StatusMascotState {
        let now = Date()
        if isRestartingGatewayManually {
            return .restarting
        }
        if status.state == .repairing || status.state == .collecting {
            return .fixing
        }
        if status.state == .restarting {
            return .restarting
        }
        if status.state == .crashDetected {
            return .error
        }
        if status.state == .exhausted {
            return .failed
        }
        if status.state == .maintenance,
           (status.detail.contains("重启") || status.detail.contains("恢复") || status.detail.contains("宽限期")) {
            return .restarting
        }
        if let successAt = recentRepairSuccessAt,
           now.timeIntervalSince(successAt) <= Self.recentOutcomeDisplaySeconds {
            return .success
        }
        if let failureAt = recentRepairFailureAt,
           now.timeIntervalSince(failureAt) <= Self.recentOutcomeDisplaySeconds {
            return .failed
        }
        if !daemonRunning || !isConnected || status.state == .unmonitored {
            return .error
        }
        return isAgentLoopBusy ? .busy : .idle
    }

    var menuBarSymbolName: String {
        switch mascotState {
        case .idle:
            return "face.smiling"
        case .busy:
            return "bolt.horizontal.circle.fill"
        case .restarting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .fixing:
            return "wrench.and.screwdriver.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var statusHeadline: String {
        if isRestartingGatewayManually {
            return "正在重启 OpenClaw Gateway"
        }
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
        if isRestartingGatewayManually {
            return manualGatewayRestartPhase.detail
        }
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

    private func applyStatusUpdate(_ newStatus: KeepStatusModel) {
        let oldState = status.state
        status = newStatus
        handleRepairOutcomeTransition(from: oldState, to: newStatus)
    }

    private func performGatewayRestart() async {
        let grace = max(config.monitor.exitGracePeriodSec, 1)
        let previousPID = status.pid

        manualGatewayRestartPhase = .enteringMaintenance
        do {
            try await ipcClient.enterMaintenance(durationSec: grace, reason: "应用内正在重启 OpenClaw Gateway")

            manualGatewayRestartPhase = .sendingCommand
            do {
                try await Task.detached(priority: .userInitiated) {
                    let manager = DaemonManager()
                    try manager.restartGateway()
                }.value
            } catch {
                try? await ipcClient.exitMaintenance()
                throw error
            }

            manualGatewayRestartPhase = .waitingForConfirmation
            _ = try await waitForGatewayRestartConfirmation(previousPID: previousPID, timeoutSec: max(grace + 8, 10))
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        manualGatewayRestartPhase = .idle
    }

    private func waitForGatewayRestartConfirmation(previousPID: Int, timeoutSec: Int) async throws -> Int {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        var observedDown = false

        while Date() < deadline {
            let latest = try await ipcClient.fetchStatus()
            applyStatusUpdate(latest)

            if previousPID > 0, latest.pid > 0, latest.pid != previousPID {
                return latest.pid
            }

            if latest.pid == 0 || latest.detail.contains("退出") || latest.detail.contains("不可达") || latest.detail.contains("等待最多") {
                observedDown = true
            }

            if observedDown, latest.state == .watching, latest.pid > 0 {
                return latest.pid
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        try? await ipcClient.exitMaintenance()
        let hint: String
        if previousPID > 0 {
            hint = "在 \(timeoutSec) 秒内没有观察到 PID 从 \(previousPID) 变更，也没有看到服务先掉线再恢复"
        } else {
            hint = "在 \(timeoutSec) 秒内没有看到服务先掉线再恢复"
        }
        throw NSError(
            domain: "ClawKeep",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "重启命令已执行，但\(hint)，暂时无法确认 Gateway 真的完成了重启。"]
        )
    }

    private func handleRepairOutcomeTransition(from oldState: KeepStatusModel.State, to newStatus: KeepStatusModel) {
        let now = Date()
        if newStatus.state == .exhausted {
            recentRepairFailureAt = now
            return
        }
        if newStatus.state == .watching {
            if oldState == .repairing || oldState == .collecting || oldState == .restarting || newStatus.detail.contains("修复完成") {
                recentRepairSuccessAt = now
                recentRepairFailureAt = nil
            }
        }
    }

    private func startAgentLoopActivityPolling() {
        activityPollTask?.cancel()
        activityPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let delay = await self.pollAgentLoopActivityOnce()
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func startMenuBarAnimation() {
        menuBarAnimationTask?.cancel()
        menuBarAnimationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.menuBarAnimationTick = (self.menuBarAnimationTick + 1) % 10_000
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func pollAgentLoopActivityOnce() async -> UInt64 {
        let now = Date()
        if now.timeIntervalSince(lastSessionPathRefreshAt) >= Self.sessionPathRefreshIntervalSec {
            sessionIndexPaths = await Task.detached(priority: .utility) {
                Self.discoverSessionIndexPaths()
            }.value
            lastSessionPathRefreshAt = now
        }

        let indexPaths = sessionIndexPaths
        let fingerprints = sessionFileFingerprints
        let hasLoopSignal = await Task.detached(priority: .utility) {
            Self.scanRecentLoopSignal(
                sessionIndexPaths: indexPaths,
                activeWindowMs: Self.sessionActiveWindowMs,
                tailBytes: Self.sessionTailScanBytes,
                previousFingerprints: fingerprints
            )
        }.value
        sessionFileFingerprints = hasLoopSignal.fingerprints

        if hasLoopSignal.hasSignal {
            lastAgentLoopSignalAt = now
        }
        let busy = {
            guard let signalAt = lastAgentLoopSignalAt else { return false }
            return now.timeIntervalSince(signalAt) <= Self.loopBusyHoldSeconds
        }()
        if isAgentLoopBusy != busy {
            isAgentLoopBusy = busy
        }
        return busy ? Self.busyPollIntervalNs : Self.idlePollIntervalNs
    }

    nonisolated private static func discoverSessionIndexPaths() -> [String] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let homeItems = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        let roots = homeItems
            .filter { $0.hasPrefix(".openclaw") }
            .map { "\(home)/\($0)/agents" }
        var paths = Set<String>()

        for root in roots {
            guard let items = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let candidate = "\(root)/\(item)/sessions/sessions.json"
                guard fileManager.fileExists(atPath: candidate) else { continue }
                paths.insert(candidate)
            }
        }
        return Array(paths).sorted()
    }

    nonisolated private static func scanRecentLoopSignal(sessionIndexPaths: [String], activeWindowMs: Int64, tailBytes: Int, previousFingerprints: [String: UInt64]) -> LoopSignalScanResult {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        var hasSignal = false
        var fingerprints = previousFingerprints
        var activeFiles = Set<String>()
        for indexPath in sessionIndexPaths {
            let sessions = loadSessionEntries(from: indexPath)
            for session in sessions {
                guard nowMs - session.updatedAtMs <= activeWindowMs else { continue }
                activeFiles.insert(session.sessionFile)
                guard let fingerprint = fileFingerprint(path: session.sessionFile) else { continue }
                if fingerprints[session.sessionFile] == fingerprint {
                    continue
                }
                fingerprints[session.sessionFile] = fingerprint
                if fileContainsLoopSignal(path: session.sessionFile, tailBytes: tailBytes) {
                    hasSignal = true
                }
            }
        }

        fingerprints = fingerprints.filter { activeFiles.contains($0.key) }
        return LoopSignalScanResult(hasSignal: hasSignal, fingerprints: fingerprints)
    }

    nonisolated private static func loadSessionEntries(from indexPath: String) -> [SessionIndexEntry] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return []
        }

        var entries: [SessionIndexEntry] = []
        entries.reserveCapacity(root.count)
        for value in root.values {
            guard
                let item = value as? [String: Any],
                let updatedAt = asInt64(item["updatedAt"]),
                let sessionFile = item["sessionFile"] as? String,
                !sessionFile.isEmpty
            else {
                continue
            }
            entries.append(SessionIndexEntry(updatedAtMs: updatedAt, sessionFile: sessionFile))
        }
        return entries
    }

    nonisolated private static func asInt64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    nonisolated private static func fileContainsLoopSignal(path: String, tailBytes: Int) -> Bool {
        guard let tail = readFileTail(path: path, maxBytes: tailBytes) else { return false }
        return tail.contains("\"type\":\"thinking\"")
            || tail.contains("\"type\":\"toolCall\"")
            || tail.contains("\"type\":\"toolResult\"")
            || tail.contains("\"role\":\"toolResult\"")
    }

    nonisolated private static func readFileTail(path: String, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer {
                try? handle.close()
            }
            let endOffset = try handle.seekToEnd()
            let startOffset = endOffset > UInt64(maxBytes) ? endOffset - UInt64(maxBytes) : 0
            try handle.seek(toOffset: startOffset)
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    nonisolated private static func fileFingerprint(path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let millis = UInt64(max(0, modifiedAt) * 1_000)
        return (millis << 20) ^ (size & 0x000F_FFFF)
    }

    private struct SessionIndexEntry {
        let updatedAtMs: Int64
        let sessionFile: String
    }

    private struct LoopSignalScanResult {
        let hasSignal: Bool
        let fingerprints: [String: UInt64]
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
