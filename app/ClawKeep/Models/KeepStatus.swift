import Foundation

struct KeepStatusModel: Codable, Equatable {
    enum State: String, Codable {
        case unmonitored
        case watching
        case maintenance
        case crashDetected = "crash_detected"
        case collecting
        case repairing
        case restarting
        case exhausted
    }

    var state: State = .unmonitored
    var processName: String = "openclaw-gateway"
    var pid: Int = 0
    var exitCode: Int = 0
    var crashCount: Int = 0
    var repairAttempts: Int = 0
    var lastArchive: String = ""
    var detail: String = ""
    var lastCrashTime: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case state
        case processName
        case pid
        case exitCode
        case crashCount
        case repairAttempts
        case lastArchive
        case detail
        case lastCrashTime
        case updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .unmonitored
        processName = try container.decodeIfPresent(String.self, forKey: .processName) ?? "openclaw-gateway"
        pid = try container.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        crashCount = try container.decodeIfPresent(Int.self, forKey: .crashCount) ?? 0
        repairAttempts = try container.decodeIfPresent(Int.self, forKey: .repairAttempts) ?? 0
        lastArchive = try container.decodeIfPresent(String.self, forKey: .lastArchive) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        lastCrashTime = sanitize(date: try container.decodeIfPresent(Date.self, forKey: .lastCrashTime))
        updatedAt = sanitize(date: try container.decodeIfPresent(Date.self, forKey: .updatedAt))
    }

    var symbolName: String {
        switch state {
        case .watching:
            return "checkmark.shield.fill"
        case .maintenance:
            return "wrench.and.screwdriver.fill"
        case .crashDetected, .exhausted:
            return "exclamationmark.shield.fill"
        case .collecting, .repairing, .restarting:
            return "shield.lefthalf.filled"
        case .unmonitored:
            return "shield.fill"
        }
    }

    var statusText: String {
        switch state {
        case .watching:
            return "运行中"
        case .maintenance:
            return "维护中"
        case .crashDetected:
            return "崩溃"
        case .collecting:
            return "采集中"
        case .repairing:
            return "修复中"
        case .restarting:
            return "重启中"
        case .exhausted:
            return "需人工介入"
        case .unmonitored:
            return "未监控"
        }
    }

    private func sanitize(date: Date?) -> Date? {
        guard let date else { return nil }
        return date.timeIntervalSince1970 <= 0 ? nil : date
    }
}
