import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var status = KeepStatusModel()
    @Published var logs: [String] = []
    @Published var config = AppConfig()
    @Published var daemonRunning = false
    @Published var isConnected = false
    @Published var errorMessage = ""

    let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("claw-keep.sock")
    let configPath = ("~/.claw-keep/config.toml" as NSString).expandingTildeInPath

    private let daemonManager = DaemonManager()
    private let grpcClient = GRPCClient()
    private var didStart = false
    private var connectionTask: Task<Void, Never>?

    func bootstrap() {
        guard !didStart else { return }
        didStart = true

        Task {
            do {
                try daemonManager.ensureDefaultConfig(at: configPath)
                try daemonManager.start(configPath: configPath, socketPath: socketPath)
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
                try await grpcClient.connect(socketPath: socketPath)
                config = try await grpcClient.fetchConfig()
                status = try await grpcClient.fetchStatus()
                isConnected = true
                errorMessage = ""
                backoffSeconds = 1

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [grpcClient] in
                        try await grpcClient.subscribeStatus { [weak self] newStatus in
                            await MainActor.run {
                                self?.status = newStatus
                            }
                        }
                    }
                    group.addTask { [grpcClient] in
                        try await grpcClient.subscribeLogs { [weak self] line in
                            await MainActor.run {
                                self?.logs.append(line)
                                if self?.logs.count ?? 0 > 500 {
                                    self?.logs.removeFirst()
                                }
                            }
                        }
                    }
                    try await group.waitForAll()
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
        Task {
            do {
                config = try await grpcClient.updateConfig(config)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func triggerRepair() {
        Task {
            do {
                try await grpcClient.triggerRepair()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func restart() {
        Task {
            do {
                try await grpcClient.restart()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resetMonitoring() {
        Task {
            do {
                try await grpcClient.resetMonitoring()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func testNotify(channel: String) {
        Task {
            do {
                try await grpcClient.testNotify(channel: channel)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
