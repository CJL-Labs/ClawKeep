import Foundation

final class DaemonManager {
    private var process: Process?
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func ensureDefaultConfig(at path: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            return
        }
        try fileManager.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)

        let bundledConfig = Bundle.main.url(forResource: "config.example", withExtension: "toml")
        if let bundledConfig {
            try fileManager.copyItem(at: bundledConfig, to: URL(fileURLWithPath: path))
            return
        }
        try fileManager.copyItem(at: repoRoot.appendingPathComponent("config.example.toml"), to: URL(fileURLWithPath: path))
    }

    func start(configPath: String, socketPath: String) throws {
        guard process == nil || process?.isRunning == false else {
            return
        }

        let binaryURL = try resolveDaemonBinary()
        let task = Process()
        task.executableURL = binaryURL
        task.arguments = ["-config", configPath, "-socket", socketPath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        process = task
    }

    private func resolveDaemonBinary() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "keepd", withExtension: nil) {
            return bundled
        }
        let repoBinary = repoRoot.appendingPathComponent("keepd/keepd")
        if FileManager.default.fileExists(atPath: repoBinary.path) {
            return repoBinary
        }
        throw NSError(domain: "ClawKeep", code: 1, userInfo: [NSLocalizedDescriptionKey: "keepd binary not found"])
    }
}
