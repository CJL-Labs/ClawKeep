import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

@MainActor
final class GRPCClient {
    private var socketPath = ""

    func connect(socketPath: String) async throws {
        self.socketPath = socketPath
    }

    func fetchStatus() async throws -> SentinelStatusModel {
        let response: Sentinel_V1_GetStatusResponse = try await withClient { client in
            try await client.getStatus(.init())
        }
        return mapStatus(response.status)
    }

    func fetchConfig() async throws -> Sentinel_V1_AppConfig {
        let response: Sentinel_V1_GetConfigResponse = try await withClient { client in
            try await client.getConfig(.init())
        }
        return response.config
    }

    func updateConfig(_ config: Sentinel_V1_AppConfig) async throws -> Sentinel_V1_AppConfig {
        var request = Sentinel_V1_UpdateConfigRequest()
        request.config = config
        let finalRequest = request
        let response: Sentinel_V1_UpdateConfigResponse = try await withClient { client in
            try await client.updateConfig(finalRequest)
        }
        return response.config
    }

    func triggerRepair() async throws {
        _ = try await withClient { client in
            try await client.triggerRepair(.init())
        } as Sentinel_V1_TriggerRepairResponse
    }

    func restart() async throws {
        _ = try await withClient { client in
            try await client.restart(.init())
        } as Sentinel_V1_RestartResponse
    }

    func resetMonitoring() async throws {
        _ = try await withClient { client in
            try await client.resetMonitoring(.init())
        } as Sentinel_V1_ResetMonitoringResponse
    }

    func testNotify(channel: String) async throws {
        var request = Sentinel_V1_TestNotifyRequest()
        request.channel = channel
        let finalRequest = request
        _ = try await withClient { client in
            try await client.testNotify(finalRequest)
        } as Sentinel_V1_TestNotifyResponse
    }

    func startStatusStream(onEvent: @escaping @Sendable (SentinelStatusModel) async -> Void, onError: @escaping @Sendable (Error) async -> Void) {
        Task.detached {
            do {
                try await self.withClient { client in
                    try await client.subscribeStatus(.init()) { response in
                        for try await event in response.messages {
                            await onEvent(self.mapStatus(event.status))
                        }
                    }
                } as Void
            } catch {
                await onError(error)
            }
        }
    }

    func startLogStream(onEvent: @escaping @Sendable (String) async -> Void, onError: @escaping @Sendable (Error) async -> Void) {
        Task.detached {
            do {
                var request = Sentinel_V1_SubscribeLogsRequest()
                request.maxBacklog = 50
                let finalRequest = request
                try await self.withClient { client in
                    try await client.subscribeLogs(finalRequest) { response in
                        for try await entry in response.messages {
                            await onEvent("[\(entry.level)] \(entry.message)")
                        }
                    }
                } as Void
            } catch {
                await onError(error)
            }
        }
    }

    private func withClient<Result: Sendable>(_ body: @escaping @Sendable (Sentinel_V1_SentinelService.Client<HTTP2ClientTransport.Posix>) async throws -> Result) async throws -> Result {
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
        ) { grpcClient in
            let client = Sentinel_V1_SentinelService.Client(wrapping: grpcClient)
            return try await body(client)
        }
    }

    nonisolated private func mapStatus(_ status: Sentinel_V1_SentinelStatus) -> SentinelStatusModel {
        var model = SentinelStatusModel()
        model.processName = status.processName
        model.pid = status.pid
        model.exitCode = status.exitCode
        model.crashCount = status.crashCount
        model.repairAttempts = status.repairAttempts
        model.lastArchive = status.lastArchive
        model.detail = status.detail
        if status.hasLastCrashTime {
            model.lastCrashTime = status.lastCrashTime.date
        }
        if status.hasUpdatedAt {
            model.updatedAt = status.updatedAt.date
        }
        switch status.state {
        case .watching:
            model.state = .watching
        case .crashDetected:
            model.state = .crashDetected
        case .collecting:
            model.state = .collecting
        case .repairing:
            model.state = .repairing
        case .restarting:
            model.state = .restarting
        case .exhausted:
            model.state = .exhausted
        default:
            model.state = .unmonitored
        }
        return model
    }
}
