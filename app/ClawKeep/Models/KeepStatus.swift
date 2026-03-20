import Foundation

struct KeepStatusModel: Equatable {
    enum State: String {
        case unmonitored
        case watching
        case crashDetected
        case collecting
        case repairing
        case restarting
        case exhausted
    }

    var state: State = .unmonitored
    var processName: String = "openclaw-gateway"
    var pid: Int32 = 0
    var exitCode: Int32 = 0
    var crashCount: Int32 = 0
    var repairAttempts: Int32 = 0
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
