import Foundation
import SwiftUI
import SwiftProtobuf

@MainActor
final class AppState: ObservableObject {
    @Published var status = KeepStatusModel()
    @Published var logs: [String] = []
    @Published var config = Keep_V1_AppConfig()
    @Published var daemonRunning = false
    @Published var isConnected = false
    @Published var errorMessage = ""

    let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("claw-keep.sock")
    let configPath = ("~/.claw-keep/config.toml" as NSString).expandingTildeInPath

    private let daemonManager = DaemonManager()
    private let grpcClient = GRPCClient()
    private var didStart = false

    func bootstrap() {
        guard !didStart else { return }
        didStart = true

        Task {
            do {
                try daemonManager.ensureDefaultConfig(at: configPath)
                try daemonManager.start(configPath: configPath, socketPath: socketPath)
                daemonRunning = true
                try await grpcClient.connect(socketPath: socketPath)
                isConnected = true
                config = try await grpcClient.fetchConfig()
                status = try await grpcClient.fetchStatus()
                startStreams()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startStreams() {
        grpcClient.startStatusStream { [weak self] newStatus in
            await MainActor.run {
                self?.status = newStatus
            }
        } onError: { [weak self] error in
            await MainActor.run {
                self?.isConnected = false
                self?.errorMessage = error.localizedDescription
            }
        }

        grpcClient.startLogStream { [weak self] line in
            await MainActor.run {
                self?.logs.append(line)
                if self?.logs.count ?? 0 > 500 {
                    self?.logs.removeFirst()
                }
            }
        } onError: { _ in }
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
