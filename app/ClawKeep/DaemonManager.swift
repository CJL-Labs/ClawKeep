import Darwin
import Foundation

struct DetectedAgent: Equatable, Identifiable {
    let name: String
    let displayName: String
    let cliPath: String
    let cliArgs: [String]

    var id: String { name }
}

struct RuntimeDiscovery: Equatable {
    var openClawPath: String?
    var agents: [DetectedAgent] = []
}

final class DaemonManager {
    private var process: Process?
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private let helperDirectory = ("~/.claw-keep/bin" as NSString).expandingTildeInPath

    func discoverRuntime() -> RuntimeDiscovery {
        RuntimeDiscovery(
            openClawPath: resolveCommand("openclaw", fallbacks: [
                ("~/.nvm/versions/node/*/bin/openclaw" as NSString).expandingTildeInPath,
                ("~/.local/bin/openclaw" as NSString).expandingTildeInPath,
                "/opt/homebrew/bin/openclaw",
                "/usr/local/bin/openclaw"
            ]),
            agents: [
                detectedAgent(
                    name: "claude",
                    displayName: "Claude Code",
                    command: "claude",
                    cliArgs: ["--dangerously-skip-permissions", "-p", "{{prompt}}"],
                    fallbacks: [
                        "/opt/homebrew/bin/claude",
                        "/usr/local/bin/claude",
                        ("~/.local/bin/claude" as NSString).expandingTildeInPath
                    ]
                ),
                detectedAgent(
                    name: "codex",
                    displayName: "Codex",
                    command: "codex",
                    cliArgs: ["exec", "--skip-git-repo-check", "{{prompt}}"],
                    fallbacks: [
                        "/opt/homebrew/bin/codex",
                        "/usr/local/bin/codex"
                    ]
                )
            ].compactMap { $0 }
        )
    }

    func ensureDefaultConfig(at path: String, discovery: RuntimeDiscovery) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            if try shouldRewriteConfig(at: path) {
                try defaultConfigContents(discovery: discovery).write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                return
            }
            try repairConfigIfNeeded(at: path, discovery: discovery)
            return
        }
        try fileManager.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try defaultConfigContents(discovery: discovery).write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    func start(configPath: String, socketPath: String) throws {
        if isDaemonHealthy(at: socketPath), matchingDaemonPIDs(for: socketPath).count <= 1 {
            return
        }
        try cleanupStaleDaemon(socketPath: socketPath)
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

        guard waitForHealthyDaemon(socketPath, timeout: 5) else {
            if task.isRunning {
                task.terminate()
            }
            process = nil
            throw NSError(domain: "ClawKeep", code: 2, userInfo: [NSLocalizedDescriptionKey: "keepd 启动失败，后台连接没有建立成功。"])
        }
    }

    func restartGateway() throws {
        guard let openClawPath = discoverRuntime().openClawPath else {
            throw NSError(domain: "ClawKeep", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有找到 openclaw 命令，无法执行重启。"])
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", shellQuoted(openClawPath) + " gateway restart"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw NSError(domain: "ClawKeep", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "重启 OpenClaw Gateway 失败：\(message)"])
        }
    }

    private func resolveDaemonBinary() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "keepd", withExtension: nil) {
            return try prepareBundledDaemon(at: bundled)
        }
        let repoBinary = repoRoot.appendingPathComponent("keepd/keepd")
        if FileManager.default.fileExists(atPath: repoBinary.path) {
            return repoBinary
        }
        throw NSError(domain: "ClawKeep", code: 1, userInfo: [NSLocalizedDescriptionKey: "keepd binary not found"])
    }

    private func prepareBundledDaemon(at bundledURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let helperRoot = URL(fileURLWithPath: helperDirectory, isDirectory: true)
        try fileManager.createDirectory(at: helperRoot, withIntermediateDirectories: true)

        let extractedURL = helperRoot.appendingPathComponent("keepd")
        if shouldRefreshExtractedHelper(source: bundledURL, destination: extractedURL) {
            if fileManager.fileExists(atPath: extractedURL.path) {
                try fileManager.removeItem(at: extractedURL)
            }
            try fileManager.copyItem(at: bundledURL, to: extractedURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedURL.path)
        }
        return extractedURL
    }

    private func shouldRefreshExtractedHelper(source: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path) else { return true }

        let sourceValues = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let destinationValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])

        if sourceValues?.fileSize != destinationValues?.fileSize {
            return true
        }

        let sourceDate = sourceValues?.contentModificationDate ?? .distantPast
        let destinationDate = destinationValues?.contentModificationDate ?? .distantPast
        return sourceDate > destinationDate
    }

    private func repairConfigIfNeeded(at path: String, discovery: RuntimeDiscovery) throws {
        var contents = try String(contentsOfFile: path, encoding: .utf8)
        let original = contents

        contents = contents.replacingOccurrences(
            of: """
        watch_paths = [
          "/tmp/openclaw/",
          "~/.openclaw/logs/"
        ]
        """,
            with: """
        watch_paths = [
          "/tmp/openclaw/openclaw-*.log",
          "~/.openclaw/logs/gateway.log",
          "~/.openclaw/logs/gateway.err.log"
        ]
        """
        )
        contents = contents.replacingOccurrences(
            of: """
        watch_paths = [
          "/tmp/openclaw/openclaw-*.log",
          "~/.openclaw/logs/gateway.log"
          "~/.openclaw/logs/gateway.err.log"
        ]
        """,
            with: """
        watch_paths = [
          "/tmp/openclaw/openclaw-*.log",
          "~/.openclaw/logs/gateway.log",
          "~/.openclaw/logs/gateway.err.log"
        ]
        """
        )
        if let openClawPath = discovery.openClawPath {
            contents = contents.replacingOccurrences(of: "/usr/local/bin/openclaw", with: openClawPath)
            contents = contents.replacingOccurrences(of: "/opt/homebrew/bin/openclaw", with: openClawPath)
        }

        for agent in discovery.agents {
            switch agent.name {
            case "claude":
                contents = contents.replacingOccurrences(of: "/usr/local/bin/claude", with: agent.cliPath)
                contents = contents.replacingOccurrences(of: "/opt/homebrew/bin/claude", with: agent.cliPath)
                contents = contents.replacingOccurrences(of: #"cli_args = ["-p", "--model", "sonnet"]"#, with: #"cli_args = ["--dangerously-skip-permissions", "-p", "{{prompt}}"]"#)
                contents = contents.replacingOccurrences(of: #"cli_args = ["-p"]"#, with: #"cli_args = ["--dangerously-skip-permissions", "-p", "{{prompt}}"]"#)
            case "codex":
                contents = contents.replacingOccurrences(of: "/usr/local/bin/codex", with: agent.cliPath)
                contents = contents.replacingOccurrences(of: "/opt/homebrew/bin/codex", with: agent.cliPath)
                contents = contents.replacingOccurrences(of: #"cli_args = ["exec"]"#, with: #"cli_args = ["exec", "{{prompt}}"]"#)
                contents = contents.replacingOccurrences(of: #"cli_args = ["exec", "{{prompt}}"]"#, with: #"cli_args = ["exec", "--skip-git-repo-check", "{{prompt}}"]"#)
            default:
                break
            }
        }

        if contents != original {
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func shouldRewriteConfig(at path: String) throws -> Bool {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }

        let requiredMarkers = [
            "[monitor]",
            "[agent]",
            "[repair]",
            "[notify]",
            "[daemon]"
        ]
        return requiredMarkers.contains { !contents.contains($0) }
    }

    private func defaultConfigContents(discovery: RuntimeDiscovery) -> String {
        let defaultAgent = discovery.agents.first?.name ?? "claude"
        let openClawHome = ("~/.openclaw/" as NSString).expandingTildeInPath

        let agentSections = discovery.agents.isEmpty ? """
        [[agent.agents]]
        name = "claude"
        cli_path = "/usr/local/bin/claude"
        cli_args = ["--dangerously-skip-permissions", "-p", "{{prompt}}"]
        working_dir = "\(openClawHome)"
        timeout_sec = 300
        """ : discovery.agents.map { agent in
            """
            [[agent.agents]]
            name = "\(agent.name)"
            cli_path = "\(agent.cliPath)"
            cli_args = [\(agent.cliArgs.map { "\"\($0)\"" }.joined(separator: ", "))]
            working_dir = "\(openClawHome)"
            timeout_sec = 300
            """
        }.joined(separator: "\n\n")

        return """
        [monitor]
        process_name = "openclaw-gateway"
        pid_file = "~/.openclaw/gateway.pid"
        host = "127.0.0.1"
        port = 18789
        enable_kqueue = true
        enable_tcp_probe = true
        tcp_probe_timeout_ms = 3000
        health_command = ""
        exit_grace_period_sec = 20
        restart_cooldown_sec = 30
        max_restart_attempts = 5

        [log]
        watch_paths = [
          "/tmp/openclaw/openclaw-*.log",
          "~/.openclaw/logs/gateway.log",
          "~/.openclaw/logs/gateway.err.log"
        ]
        [agent]
        default_agent = "\(defaultAgent)"

        \(agentSections)

        [repair]
        auto_repair = true
        max_repair_attempts = 3
        prompt_template = \"\"\"
        OpenClaw Gateway 崩溃了。你需要先判断原因，然后直接完成修复并恢复服务。

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
        \"\"\"

        [notify]
        notify_on = ["crash", "repair_start", "repair_success", "repair_fail", "agent_timeout"]

        [notify.feishu]
        enabled = false
        webhook_url = ""

        [notify.bark]
        enabled = false
        push_url = ""

        [daemon]
        log_level = "info"
        log_dir = "~/.claw-keep/logs/"
        log_retain_days = 7
        """
    }

    private func detectedAgent(name: String, displayName: String, command: String, cliArgs: [String], fallbacks: [String]) -> DetectedAgent? {
        guard let path = resolveCommand(command, fallbacks: fallbacks) else { return nil }
        return DetectedAgent(name: name, displayName: displayName, cliPath: path, cliArgs: cliArgs)
    }

    private func resolveCommand(_ command: String, fallbacks: [String]) -> String? {
        if let shellPath = resolveViaShell(command) {
            return shellPath
        }
        for path in fallbacks {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.contains("*") || expanded.contains("?") || expanded.contains("[") {
                if let match = globFirstExecutable(expanded) {
                    return match
                }
                continue
            }
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    private func globFirstExecutable(_ pattern: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "for p in \(shellQuoted(pattern)); do [ -x \"$p\" ] && { printf '%s\\n' \"$p\"; break; }; done"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func resolveViaShell(_ command: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private func waitForHealthyDaemon(_ socketPath: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isDaemonHealthy(at: socketPath) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    private func isDaemonHealthy(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Data(path.utf8CString.map { UInt8(bitPattern: $0) })
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }

        let addressLength = socklen_t(
            MemoryLayout.size(ofValue: address.sun_len) +
            MemoryLayout.size(ofValue: address.sun_family) +
            pathBytes.count
        )

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connectResult == 0 else { return false }

        let payload = #"{"action":"get_status"}"#
        let request = Data(payload.utf8) + Data([0x0A])
        let writeResult = request.withUnsafeBytes { rawBuffer in
            Darwin.write(fd, rawBuffer.baseAddress, request.count)
        }
        guard writeResult == request.count else { return false }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        let setOptResult = withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        guard setOptResult == 0 else { return false }

        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return false }
        let response = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
        return response.contains(#""ok":true"#)
    }

    private func cleanupStaleDaemon(socketPath: String) throws {
        let pids = matchingDaemonPIDs(for: socketPath)
        for pid in pids {
            _ = kill(pid_t(pid), SIGTERM)
        }
        if !pids.isEmpty {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if matchingDaemonPIDs(for: socketPath).isEmpty {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            for pid in matchingDaemonPIDs(for: socketPath) {
                _ = kill(pid_t(pid), SIGKILL)
            }
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func matchingDaemonPIDs(for socketPath: String) -> [Int32] {
        let quotedSocketPath = socketPath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "pgrep -f -- '\\-socket \(quotedSocketPath)' || true"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int32($0) }
                .filter { $0 > 0 }
        } catch {
            return []
        }
    }
}
