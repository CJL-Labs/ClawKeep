import AppKit
import CryptoKit
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
    @Published private(set) var updateState: AppUpdateState
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
    private var updateScheduleTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var suppressAutosave = false
    private var lastPersistedConfig: AppConfig?
    private var isPersistingConfig = false
    private var pendingConfigSave = false
    private var recentRepairSuccessAt: Date?
    private var recentRepairFailureAt: Date?
    private var sessionIndexPaths: [String] = []
    private var sessionFileFingerprints: [String: UInt64] = [:]
    private var lastSessionPathRefreshAt: Date = .distantPast
    private let defaults: UserDefaults

    nonisolated private static let sessionPathRefreshIntervalSec: TimeInterval = 8
    nonisolated private static let sessionActiveWindowMs: Int64 = 7_000
    nonisolated private static let loopBusyHoldSeconds: TimeInterval = 2.8
    nonisolated private static let recentOutcomeDisplaySeconds: TimeInterval = 60
    nonisolated private static let sessionTailScanBytes: Int = 8_000
    nonisolated private static let busyPollIntervalNs: UInt64 = 350_000_000
    nonisolated private static let idlePollIntervalNs: UInt64 = 700_000_000
    nonisolated private static let launchUpdateCheckIntervalSec: TimeInterval = 18 * 60 * 60
    nonisolated private static let automaticUpdateMaintenanceMinutes = 10
    nonisolated private static let launchUpdateCheckDelayNs: UInt64 = 15_000_000_000
    nonisolated private static let automaticUpdateLastCheckedKey = "app_update.last_checked_at"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var initialUpdateState = AppUpdateState()
        if let lastCheckedAt = defaults.object(forKey: Self.automaticUpdateLastCheckedKey) as? Date {
            initialUpdateState.lastCheckedAt = lastCheckedAt
            initialUpdateState.phase = .upToDate
            initialUpdateState.message = "上次检查更新时间是 \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))。"
        } else {
            initialUpdateState.message = "每天约 \(AppUpdateSupport.automaticCheckTimeDescription(defaults: defaults)) 自动检查一次更新。"
        }
        self.updateState = initialUpdateState
    }

    func bootstrap() {
        guard !didStart else { return }
        didStart = true
        startMenuBarAnimation()
        startAgentLoopActivityPolling()
        startAutomaticUpdateChecks()

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

    func checkForUpdates() {
        guard updateState.phase != .checking, updateState.phase != .downloading, updateState.phase != .installing else { return }
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            await self?.performUpdateCheck(userInitiated: true)
        }
    }

    func installAvailableUpdate() {
        guard updateState.phase != .checking, updateState.phase != .downloading, updateState.phase != .installing else { return }
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            await self?.performInstallAvailableUpdate()
        }
    }

    func openLatestReleasePage() {
        let fallbackURL = URL(string: "https://github.com/CJL-Labs/ClawKeep/releases/latest")!
        let url = updateState.availableUpdate?.releasePageURL ?? fallbackURL
        NSWorkspace.shared.open(url)
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

    var canCheckForUpdates: Bool {
        switch updateState.phase {
        case .checking, .downloading, .installing:
            return false
        default:
            return true
        }
    }

    var canInstallAvailableUpdate: Bool {
        updateState.availableUpdate != nil && updateState.phase != .checking && updateState.phase != .downloading && updateState.phase != .installing
    }

    var hasAvailableUpdateReleasePage: Bool {
        updateState.availableUpdate?.releasePageURL != nil
    }

    var automaticUpdateTimeDescription: String {
        AppUpdateSupport.automaticCheckTimeDescription(defaults: defaults)
    }

    var updateStatusTitle: String {
        switch updateState.phase {
        case .checking:
            return "正在检查更新"
        case .downloading:
            return "正在下载更新"
        case .installing:
            return "正在安装更新"
        case .updateAvailable:
            if let update = updateState.availableUpdate {
                return "发现新版本 \(update.displayVersion)"
            }
            return "发现新版本"
        case .failed:
            return "更新失败"
        case .upToDate:
            return "当前已是最新版本"
        case .idle:
            return "应用更新"
        }
    }

    var updateStatusDetail: String {
        var parts = [updateState.message]
        if let lastCheckedAt = updateState.lastCheckedAt {
            parts.append("上次检查: \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        parts.append("自动检查时间: 每天约 \(automaticUpdateTimeDescription)")
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
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
                // PID changed = restart confirmed. Exit maintenance to cancel
                // the recovery window, then pause briefly so the user sees
                // the restarting animation before we return success.
                try? await ipcClient.exitMaintenance()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return latest.pid
            }

            if latest.pid == 0 || latest.detail.contains("退出") || latest.detail.contains("不可达") || latest.detail.contains("等待最多") {
                observedDown = true
            }

            if observedDown, latest.state == .watching, latest.pid > 0 {
                try? await ipcClient.exitMaintenance()
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
        if newStatus.state == .exhausted, oldState != .exhausted {
            recentRepairFailureAt = now
            return
        }
        if newStatus.state == .watching {
            let recoveredFromRepairFlow = oldState == .repairing || oldState == .collecting || oldState == .restarting
            let firstWatchingUpdateWithSuccessDetail = oldState != .watching && newStatus.detail.contains("修复完成")
            if recoveredFromRepairFlow || firstWatchingUpdateWithSuccessDetail {
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

    private func startAutomaticUpdateChecks() {
        updateScheduleTask?.cancel()
        updateScheduleTask = Task { [weak self] in
            guard let self else { return }

            if self.shouldRunLaunchUpdateCheck() {
                try? await Task.sleep(nanoseconds: Self.launchUpdateCheckDelayNs)
                guard !Task.isCancelled else { return }
                await self.performUpdateCheck(userInitiated: false)
            }

            while !Task.isCancelled {
                let nextRun = AppUpdateSupport.nextAutomaticCheckDate(defaults: self.defaults)
                let sleepSeconds = max(nextRun.timeIntervalSinceNow, 1)
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.performUpdateCheck(userInitiated: false)
            }
        }
    }

    private func shouldRunLaunchUpdateCheck() -> Bool {
        guard let lastCheckedAt = updateState.lastCheckedAt else { return true }
        return Date().timeIntervalSince(lastCheckedAt) >= Self.launchUpdateCheckIntervalSec
    }

    private func performUpdateCheck(userInitiated: Bool) async {
        guard updateState.phase != .checking, updateState.phase != .downloading, updateState.phase != .installing else { return }

        let existingUpdate = updateState.availableUpdate
        updateState.phase = .checking
        updateState.message = userInitiated ? "正在向 GitHub 检查最新版本。" : "正在后台检查最新版本。"

        do {
            let remoteUpdate = try await AppUpdateSupport.fetchAvailableUpdate()
            let checkedAt = Date()
            updateState.lastCheckedAt = checkedAt
            defaults.set(checkedAt, forKey: Self.automaticUpdateLastCheckedKey)

            if let remoteUpdate, AppUpdateSupport.isRemoteUpdateNewer(remoteUpdate) {
                updateState.availableUpdate = remoteUpdate
                updateState.phase = .updateAvailable
                if let publishedAt = remoteUpdate.publishedAt {
                    updateState.message = "发现新版本 \(remoteUpdate.displayVersion)，发布于 \(publishedAt.formatted(date: .abbreviated, time: .shortened))。"
                } else {
                    updateState.message = "发现新版本 \(remoteUpdate.displayVersion)。"
                }
                return
            }

            updateState.availableUpdate = nil
            updateState.phase = .upToDate
            updateState.message = userInitiated ? "当前已经是最新版本。" : "后台已检查，当前没有新版本。"
        } catch {
            updateState.availableUpdate = existingUpdate
            updateState.phase = .failed
            updateState.message = userInitiated
                ? "检查更新失败：\(error.localizedDescription)"
                : "后台检查更新失败：\(error.localizedDescription)"
        }
    }

    private func performInstallAvailableUpdate() async {
        guard let update = updateState.availableUpdate else { return }

        let targetAppURL = Bundle.main.bundleURL.standardizedFileURL
        let parentDirectory = targetAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            updateState.phase = .failed
            updateState.message = "当前安装目录不可写，自动更新需要对 \(parentDirectory.path) 有写权限。"
            return
        }

        do {
            updateState.phase = .downloading
            updateState.message = "正在下载并校验 \(update.displayVersion)。"
            let stagedAppURL = try await AppUpdateSupport.prepareUpdateBundle(for: update)

            updateState.phase = .installing
            updateState.message = "正在安装 \(update.displayVersion)，完成后会自动重启。"

            if isConnected {
                try? await ipcClient.enterMaintenance(
                    durationSec: Self.automaticUpdateMaintenanceMinutes * 60,
                    reason: "ClawKeep 正在安装新版本"
                )
            }

            let socketPath = self.socketPath
            _ = try? await Task.detached(priority: .userInitiated) {
                let manager = DaemonManager()
                try manager.stopDaemon(socketPath: socketPath)
            }.value

            try AppUpdateSupport.launchInstaller(
                sourceAppURL: stagedAppURL,
                targetAppURL: targetAppURL,
                ownerPID: getpid()
            )
            NSApplication.shared.terminate(nil)
        } catch {
            updateState.phase = .failed
            updateState.message = "安装更新失败：\(error.localizedDescription)"
        }
    }
}

struct AvailableAppUpdate: Equatable {
    let version: String
    let build: Int?
    let downloadURL: URL
    let releasePageURL: URL?
    let publishedAt: Date?
    let sha256: String?

    var displayVersion: String {
        if let build {
            return "\(version) (\(build))"
        }
        return version
    }
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case installing
    case failed
}

struct AppUpdateState: Equatable {
    var phase: AppUpdatePhase = .idle
    var availableUpdate: AvailableAppUpdate?
    var lastCheckedAt: Date?
    var message = "还没有检查更新。"
}

private struct GitHubLatestRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

private struct AppUpdateManifest: Decodable {
    let version: String
    let build: Int?
    let publishedAt: Date?
    let url: URL
    let sha256: String?
    let releasePage: URL?

    enum CodingKeys: String, CodingKey {
        case version
        case build
        case publishedAt = "published_at"
        case url
        case sha256
        case releasePage = "release_page"
    }
}

private enum AppUpdateSupport {
    static let releaseAPIURL = URL(string: "https://api.github.com/repos/CJL-Labs/ClawKeep/releases/latest")!
    static let manifestAssetName = "latest-macos.json"
    static let zipAssetPrefix = "ClawKeep-macos-"
    static let zipAssetSuffix = "-unsigned.zip"

    static func configuredRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClawKeep", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    static func currentAppVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (version?.isEmpty == false ? version : nil) ?? "0.0.0"
    }

    static func currentBuildNumber() -> Int {
        let buildString = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        return Int(buildString ?? "") ?? 0
    }

    static func isRemoteUpdateNewer(_ update: AvailableAppUpdate) -> Bool {
        let currentVersion = currentAppVersion()
        let versionComparison = currentVersion.compare(update.version, options: .numeric)
        if versionComparison == .orderedAscending {
            return true
        }
        if versionComparison == .orderedDescending {
            return false
        }

        guard let remoteBuild = update.build else { return false }
        return currentBuildNumber() < remoteBuild
    }

    static func fetchAvailableUpdate() async throws -> AvailableAppUpdate? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (releaseData, _) = try await URLSession.shared.data(for: configuredRequest(for: releaseAPIURL))
        let release = try decoder.decode(GitHubLatestRelease.self, from: releaseData)

        if let manifestAsset = release.assets.first(where: { $0.name == manifestAssetName }) {
            let (manifestData, _) = try await URLSession.shared.data(for: configuredRequest(for: manifestAsset.browserDownloadURL))
            let manifest = try decoder.decode(AppUpdateManifest.self, from: manifestData)
            return AvailableAppUpdate(
                version: manifest.version,
                build: manifest.build,
                downloadURL: manifest.url,
                releasePageURL: manifest.releasePage ?? release.htmlURL,
                publishedAt: manifest.publishedAt ?? release.publishedAt,
                sha256: manifest.sha256
            )
        }

        guard let zipAsset = release.assets.first(where: { $0.name.hasPrefix(zipAssetPrefix) && $0.name.hasSuffix(zipAssetSuffix) }) else {
            return nil
        }

        return AvailableAppUpdate(
            version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
            build: nil,
            downloadURL: zipAsset.browserDownloadURL,
            releasePageURL: release.htmlURL,
            publishedAt: release.publishedAt,
            sha256: nil
        )
    }

    static func prepareUpdateBundle(for update: AvailableAppUpdate) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let cacheRoot = try cacheDirectory(for: update)
            try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

            let archiveURL = cacheRoot.appendingPathComponent("ClawKeep-update.zip")
            let archiveExists = fileManager.fileExists(atPath: archiveURL.path)
            let archiveIsValid = archiveExists ? try verifyArchive(at: archiveURL, expectedSHA256: update.sha256) : false
            if !archiveExists || !archiveIsValid {
                let (temporaryURL, _) = try await URLSession.shared.download(for: configuredRequest(for: update.downloadURL))
                if fileManager.fileExists(atPath: archiveURL.path) {
                    try fileManager.removeItem(at: archiveURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: archiveURL)
            }

            guard try verifyArchive(at: archiveURL, expectedSHA256: update.sha256) else {
                throw NSError(
                    domain: "ClawKeep",
                    code: 301,
                    userInfo: [NSLocalizedDescriptionKey: "更新包校验失败，已停止安装。"]
                )
            }

            let extractedRoot = cacheRoot.appendingPathComponent("expanded", isDirectory: true)
            if fileManager.fileExists(atPath: extractedRoot.path) {
                try fileManager.removeItem(at: extractedRoot)
            }
            try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedRoot.path])

            guard let appURL = findAppBundle(in: extractedRoot) else {
                throw NSError(
                    domain: "ClawKeep",
                    code: 302,
                    userInfo: [NSLocalizedDescriptionKey: "解压后的更新包里没有找到 ClawKeep.app。"]
                )
            }
            return appURL
        }.value
    }

    static func launchInstaller(sourceAppURL: URL, targetAppURL: URL, ownerPID: pid_t) throws {
        let fileManager = FileManager.default
        let installerScript: URL
        if let bundled = Bundle.main.url(forResource: "install-update", withExtension: "sh") {
            installerScript = bundled
        } else {
            installerScript = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/install-update.sh")
        }

        guard fileManager.fileExists(atPath: installerScript.path) else {
            throw NSError(
                domain: "ClawKeep",
                code: 303,
                userInfo: [NSLocalizedDescriptionKey: "安装 helper 缺失，无法执行自动更新。"]
            )
        }

        let temporaryScriptURL = fileManager.temporaryDirectory.appendingPathComponent("clawkeep-install-\(UUID().uuidString).sh")
        if fileManager.fileExists(atPath: temporaryScriptURL.path) {
            try fileManager.removeItem(at: temporaryScriptURL)
        }
        try fileManager.copyItem(at: installerScript, to: temporaryScriptURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryScriptURL.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [temporaryScriptURL.path, String(ownerPID), sourceAppURL.path, targetAppURL.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
    }

    static func automaticCheckMinuteOfDay(defaults: UserDefaults = .standard) -> Int {
        let key = "app_update.minute_of_day"
        let stored = defaults.integer(forKey: key)
        if stored > 0 && stored < (24 * 60) {
            return stored
        }

        let chosen = Int.random(in: (9 * 60)...(20 * 60 + 59))
        defaults.set(chosen, forKey: key)
        return chosen
    }

    static func automaticCheckTimeDescription(defaults: UserDefaults = .standard) -> String {
        let minuteOfDay = automaticCheckMinuteOfDay(defaults: defaults)
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60
        return String(format: "%02d:%02d", hour, minute)
    }

    static func nextAutomaticCheckDate(now: Date = Date(), defaults: UserDefaults = .standard) -> Date {
        let calendar = Calendar.current
        let minuteOfDay = automaticCheckMinuteOfDay(defaults: defaults)
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        let candidate = calendar.date(from: components) ?? now.addingTimeInterval(24 * 60 * 60)
        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    private static func cacheDirectory(for update: AvailableAppUpdate) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let buildSuffix = update.build.map { "-\($0)" } ?? ""
        return caches
            .appendingPathComponent("ClawKeep", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
            .appendingPathComponent("\(update.version)\(buildSuffix)", isDirectory: true)
    }

    private static func verifyArchive(at archiveURL: URL, expectedSHA256: String?) throws -> Bool {
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return true }
        let data = try Data(contentsOf: archiveURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    private static func findAppBundle(in root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension == "app" {
                return next
            }
        }
        return nil
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ClawKeep",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output?.isEmpty == false ? output! : "执行更新命令失败。"]
            )
        }
    }
}
