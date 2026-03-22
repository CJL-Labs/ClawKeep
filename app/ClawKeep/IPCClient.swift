import Darwin
import Foundation

struct AppConfig: Codable, Equatable {
    var monitor = MonitorConfig()
    var log = LogConfig()
    var agent = AgentConfig()
    var repair = RepairConfig()
    var notify = NotifyConfig()
    var daemon = DaemonConfig()

    enum CodingKeys: String, CodingKey {
        case monitor
        case log
        case agent
        case repair
        case notify
        case daemon
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitor = try container.decodeIfPresent(MonitorConfig.self, forKey: .monitor) ?? MonitorConfig()
        log = try container.decodeIfPresent(LogConfig.self, forKey: .log) ?? LogConfig()
        agent = try container.decodeIfPresent(AgentConfig.self, forKey: .agent) ?? AgentConfig()
        repair = try container.decodeIfPresent(RepairConfig.self, forKey: .repair) ?? RepairConfig()
        notify = try container.decodeIfPresent(NotifyConfig.self, forKey: .notify) ?? NotifyConfig()
        daemon = try container.decodeIfPresent(DaemonConfig.self, forKey: .daemon) ?? DaemonConfig()
    }
}

struct MonitorConfig: Codable, Equatable {
    var processName = "openclaw-gateway"
    var pidFile = ""
    var host = "127.0.0.1"
    var port = 18789
    var enableKqueue = true
    var enableTcpProbe = true
    var tcpProbeTimeoutMs = 3000
    var healthCommand = ""
    var exitGracePeriodSec = 20
    var restartCooldownSec = 30
    var maxRestartAttempts = 5
}

struct LogConfig: Codable, Equatable {
    var watchPaths: [String] = []
}

struct AgentConfig: Codable, Equatable {
    var defaultAgent = ""
    var agents: [AgentEntry] = []
}

struct AgentEntry: Codable, Equatable {
    var name = ""
    var cliPath = ""
    var cliArgs: [String] = []
    var workingDir = ""
    var timeoutSec = 300
    var env: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case name
        case cliPath
        case cliArgs
        case workingDir
        case timeoutSec
        case env
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        cliPath = try container.decodeIfPresent(String.self, forKey: .cliPath) ?? ""
        cliArgs = try container.decodeIfPresent([String].self, forKey: .cliArgs) ?? []
        workingDir = try container.decodeIfPresent(String.self, forKey: .workingDir) ?? ""
        timeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? 300
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

struct RepairConfig: Codable, Equatable {
    var autoRepair = true
    var maxRepairAttempts = 3
    var promptTemplate = ""
}

struct NotifyConfig: Codable, Equatable {
    var notifyOn: [String] = []
    var feishu = FeishuConfig()
    var bark = BarkConfig()
    var smtp = SMTPConfig()

    enum CodingKeys: String, CodingKey {
        case notifyOn
        case feishu
        case bark
        case smtp
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notifyOn = try container.decodeIfPresent([String].self, forKey: .notifyOn) ?? []
        feishu = try container.decodeIfPresent(FeishuConfig.self, forKey: .feishu) ?? FeishuConfig()
        bark = try container.decodeIfPresent(BarkConfig.self, forKey: .bark) ?? BarkConfig()
        smtp = try container.decodeIfPresent(SMTPConfig.self, forKey: .smtp) ?? SMTPConfig()
    }
}

struct FeishuConfig: Codable, Equatable {
    var enabled = false
    var webhookURL = ""
    var secret = ""

    enum CodingKeys: String, CodingKey {
        case enabled
        case webhookURL = "webhook_url"
        case webhookUrl
        case secret
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        webhookURL = try container.decodeIfPresent(String.self, forKey: .webhookURL)
            ?? container.decodeIfPresent(String.self, forKey: .webhookUrl)
            ?? ""
        secret = try container.decodeIfPresent(String.self, forKey: .secret) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(webhookURL, forKey: .webhookURL)
        try container.encode(secret, forKey: .secret)
    }
}

struct BarkConfig: Codable, Equatable {
    var enabled = false
    var pushURL = ""

    enum CodingKeys: String, CodingKey {
        case enabled
        case pushURL = "push_url"
        case pushUrl
        case legacyServerURL = "server_url"
        case legacyServerUrl = "serverUrl"
        case legacyDeviceKey = "device_key"
        case legacyDeviceKeyCamel = "deviceKey"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        pushURL = try container.decodeIfPresent(String.self, forKey: .pushURL)
            ?? container.decodeIfPresent(String.self, forKey: .pushUrl)
            ?? ""
        if pushURL.isEmpty {
            let serverURL = try container.decodeIfPresent(String.self, forKey: .legacyServerURL)
                ?? container.decodeIfPresent(String.self, forKey: .legacyServerUrl)
                ?? ""
            let deviceKey = try container.decodeIfPresent(String.self, forKey: .legacyDeviceKey)
                ?? container.decodeIfPresent(String.self, forKey: .legacyDeviceKeyCamel)
                ?? ""
            if !serverURL.isEmpty && !deviceKey.isEmpty {
                pushURL = "\(serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(deviceKey.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(pushURL, forKey: .pushURL)
    }
}

struct SMTPConfig: Codable, Equatable {
    var enabled = false
    var host = ""
    var port = 465
    var username = ""
    var password = ""
    var from = ""
    var to: [String] = []
    var useTLS = true

    enum CodingKeys: String, CodingKey {
        case enabled
        case host
        case port
        case username
        case password
        case from
        case to
        case useTLS = "use_tls"
        case useTls
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 465
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        from = try container.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try container.decodeIfPresent([String].self, forKey: .to) ?? []
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS)
            ?? container.decodeIfPresent(Bool.self, forKey: .useTls)
            ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(useTLS, forKey: .useTLS)
    }
}

struct DaemonConfig: Codable, Equatable {
    var logLevel = "info"
    var logDir = ""
    var logRetainDays = 7
}

private struct IPCRequest: Encodable {
    var action: String
    var channel: String?
    var maxBacklog: Int?
    var durationSec: Int?
    var reason: String?
    var config: AppConfig?
}

private struct IPCResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let result: Result?
}

private enum IPCError: LocalizedError {
    case missingSocketPath
    case invalidResponse
    case connectionClosed
    case server(String)
    case socketPathTooLong
    case connectFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSocketPath:
            return "socket path is missing"
        case .invalidResponse:
            return "invalid response from keepd"
        case .connectionClosed:
            return "connection to keepd closed"
        case .server(let message):
            return message
        case .socketPathTooLong:
            return "socket path is too long"
        case .connectFailed(let message):
            return "connect keepd failed: \(message)"
        }
    }
}

private final class UnixSocketConnection: @unchecked Sendable {
    private let handle: FileHandle
    private var pending = Data()

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.connectFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Data(path.utf8CString.map { UInt8(bitPattern: $0) })
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw IPCError.socketPathTooLong
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }

        let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_len) +
                                      MemoryLayout.size(ofValue: address.sun_family) +
                                      pathBytes.count)

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connectResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw IPCError.connectFailed(message)
        }

        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func sendLine(_ data: Data) throws {
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    func readLine() throws -> Data? {
        while true {
            if let newlineIndex = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newlineIndex)
                pending.removeSubrange(...newlineIndex)
                return Data(line)
            }

            guard let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty else {
                if pending.isEmpty {
                    return nil
                }
                let line = pending
                pending.removeAll(keepingCapacity: false)
                return line
            }
            pending.append(chunk)
        }
    }

    func close() {
        try? handle.close()
    }
}

private actor SocketPathStore {
    private var socketPath = ""

    func set(_ path: String) {
        socketPath = path
    }

    func get() -> String {
        socketPath
    }
}

final class IPCClient: Sendable {
    private let socketPathStore = SocketPathStore()

    func connect(socketPath: String) async throws {
        await socketPathStore.set(socketPath)
    }

    func fetchStatus() async throws -> KeepStatusModel {
        try await request(action: "get_status", as: KeepStatusModel.self)
    }

    func fetchConfig() async throws -> AppConfig {
        try await request(action: "get_config", as: AppConfig.self)
    }

    func updateConfig(_ config: AppConfig) async throws -> AppConfig {
        try await request(action: "update_config", config: config, as: AppConfig.self)
    }

    func triggerRepair() async throws {
        _ = try await request(action: "trigger_repair", as: Bool.self)
    }

    func restartGateway() async throws {
        _ = try await request(action: "restart_gateway", as: Bool.self)
    }

    func resetMonitoring() async throws {
        _ = try await request(action: "reset_monitoring", as: Bool.self)
    }

    func testNotify(channel: String) async throws {
        _ = try await request(action: "test_notify", channel: channel, as: Bool.self)
    }

    func enterMaintenance(durationSec: Int, reason: String) async throws {
        _ = try await request(action: "enter_maintenance", durationSec: durationSec, reason: reason, as: Bool.self)
    }

    func exitMaintenance() async throws {
        _ = try await request(action: "exit_maintenance", as: Bool.self)
    }

    func subscribeStatus(onEvent: @escaping @Sendable (KeepStatusModel) async -> Void) async throws {
        try await stream(action: "subscribe_status", as: KeepStatusModel.self, onEvent: onEvent)
    }

    private func request<Result: Decodable & Sendable>(action: String, channel: String? = nil, maxBacklog: Int? = nil, durationSec: Int? = nil, reason: String? = nil, config: AppConfig? = nil, as: Result.Type) async throws -> Result {
        let socketPath = await socketPathStore.get()
        guard !socketPath.isEmpty else {
            throw IPCError.missingSocketPath
        }

        let payload = IPCRequest(action: action, channel: channel, maxBacklog: maxBacklog, durationSec: durationSec, reason: reason, config: config)
        return try await Task.detached(priority: .userInitiated) { [socketPath] in
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let connection = try UnixSocketConnection(path: socketPath)
            defer { connection.close() }

            let requestData = try encoder.encode(payload)
            try connection.sendLine(requestData)

            guard let line = try connection.readLine() else {
                throw IPCError.connectionClosed
            }

            let response = try decoder.decode(IPCResponse<Result>.self, from: line)
            guard response.ok else {
                throw IPCError.server(response.error ?? "unknown keepd error")
            }
            guard let result = response.result else {
                throw IPCError.invalidResponse
            }
            return result
        }.value
    }

    private func stream<Result: Decodable & Sendable>(action: String, maxBacklog: Int? = nil, as: Result.Type, onEvent: @escaping @Sendable (Result) async -> Void) async throws {
        let socketPath = await socketPathStore.get()
        guard !socketPath.isEmpty else {
            throw IPCError.missingSocketPath
        }

        let payload = IPCRequest(action: action, channel: nil, maxBacklog: maxBacklog, config: nil)
        let connection = try UnixSocketConnection(path: socketPath)
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let requestData = try encoder.encode(payload)
            try connection.sendLine(requestData)

            try await withTaskCancellationHandler(operation: {
                while !Task.isCancelled {
                    guard let line = try connection.readLine() else {
                        throw IPCError.connectionClosed
                    }
                    let item = try decoder.decode(Result.self, from: line)
                    await onEvent(item)
                }
            }, onCancel: {
                connection.close()
            })
        } catch {
            connection.close()
            throw error
        }
    }
}
