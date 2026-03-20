import Foundation

struct KeepStatusModel: Codable, Equatable {
    enum State: String, Codable {
        case unmonitored
        case watching
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

    var symbolName: String {
        switch state {
        case .watching:
            return "shield.checkmark"
        case .crashDetected, .exhausted:
            return "shield.slash"
        case .collecting, .repairing, .restarting:
            return "shield.lefthalf.filled"
        case .unmonitored:
            return "shield"
        }
    }

    var statusText: String {
        switch state {
        case .watching:
            return "运行中"
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
}
