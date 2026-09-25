import Foundation
import Darwin

actor ClaudeTerminalProcess: ClaudeTerminalSession {
    let executablePath: String?
    let inheritedEnvironment: [String: String]
    let temporaryRoot: URL
    let statuslineTimeoutSeconds: TimeInterval

    private var process: Process?
    private var masterFD: Int32 = -1
    private var workspace: URL?

    init(
        executablePath: String? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        statuslineTimeoutSeconds: TimeInterval = 20
    ) {
        self.executablePath = executablePath
        self.inheritedEnvironment = inheritedEnvironment
        self.temporaryRoot = temporaryRoot
        self.statuslineTimeoutSeconds = statuslineTimeoutSeconds
    }

    func start(account: AccountID) async throws {
        guard account.provider == .claude else { throw ProbeFailure.permanent("Wrong provider") }
        guard process == nil else { throw ProbeFailure.permanent("Claude session already started") }
        guard let executable = executablePath ?? ClaudeIdentityCLI.findClaude(in: inheritedEnvironment) else {
            throw ProbeFailure.permanent("Claude executable not found")
        }
        let directory = temporaryRoot.appendingPathComponent("capbar-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        workspace = directory
        let prefix = directory.appendingPathComponent("statusline-").path
        let command = "umask 077; f=$(mktemp \(Self.shellQuote(prefix + "XXXXXX"))); cat > \"$f\"; printf 'CapBar probe\\n'"
        let settings = ["statusLine": ["type": "command", "command": command]]
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        guard let settingsText = String(data: settingsData, encoding: .utf8) else {
            throw ProbeFailure.permanent("Claude statusline settings are invalid")
        }

        var environment = inheritedEnvironment
        for key in Array(environment.keys) where key.hasPrefix("ANTHROPIC_") ||
            key == "CLAUDE_CODE_OAUTH_TOKEN" || key == "CLAUDE_CODE_OAUTH_REFRESH_TOKEN" {
            environment.removeValue(forKey: key)
        }
        let defaultDirectory = AccountID(provider: .claude, directory: "~/.claude").directory
        if account.directory == defaultDirectory {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = account.directory
        }
        environment["TERM"] = "xterm-256color"

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw ProbeFailure.transient("Claude terminal could not open")
        }
        var terminalSize = winsize(ws_row: 32, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &terminalSize)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: executable)
        launched.arguments = [
            "--restricted", "--tools", "", "--strict-mcp-config", "--no-chrome",
            "--permission-mode", "manual", "--setting-sources", "",
            "--system-prompt", "Reply with exactly OK.", "--settings", settingsText
        ]
        launched.environment = environment
        launched.currentDirectoryURL = directory
        launched.standardInput = slaveHandle
        launched.standardOutput = slaveHandle
        launched.standardError = slaveHandle
        do {
            try launched.run()
        } catch {
            close(master)
            close(slave)
            try? FileManager.default.removeItem(at: directory)
            workspace = nil
            throw ProbeFailure.permanent("Claude could not start")
        }
        close(slave)
        masterFD = master
        process = launched
    }

    func converse() async throws -> ClaudeObservation? {
        guard let process, masterFD >= 0, let workspace else {
            throw ProbeFailure.permanent("Claude session is not running")
        }
        var startup = ""
        let minimumTrustAt = Date().addingTimeInterval(3)
        let startupDeadline = Date().addingTimeInterval(4)
        while Date() < startupDeadline, process.isRunning {
            startup += readAvailable()
            let visible = Self.ansiRegex.stringByReplacingMatches(in: startup, range: NSRange(startup.startIndex..., in: startup), withTemplate: "")
            let condensed = String(visible.lowercased().filter(\.isLetter))
            if Date() >= minimumTrustAt &&
                (condensed.contains("quicksafetycheck") || condensed.contains("trustthisfolder")) {
                writeToTerminal("\u{1B}[B\r")
                try await Task.sleep(for: .seconds(2))
                break
            }
            if startup.contains("READY") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.isRunning else { throw ProbeFailure.transient("Claude session exited before prompt") }
        let existingFiles = statuslineFileNames(in: workspace)
        writeToTerminal("Reply with exactly OK. Do not use tools.\r")

        let deadline = Date().addingTimeInterval(statuslineTimeoutSeconds)
        while Date() < deadline, process.isRunning {
            try Task.checkCancellation()
            _ = readAvailable()
            if let observation = newestStatusline(in: workspace, excluding: existingFiles), !observation.windows.isEmpty {
                return observation
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return newestStatusline(in: workspace, excluding: existingFiles)
    }

    func exit() async {
        guard let process, process.isRunning else { return }
        writeToTerminal("/exit\r")
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            _ = readAvailable()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func terminate() async {
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process?.waitUntilExit()
        process = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
    }

    private func writeToTerminal(_ text: String) {
        guard masterFD >= 0 else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            _ = Darwin.write(masterFD, buffer.baseAddress, buffer.count)
        }
    }

    private func readAvailable() -> String {
        guard masterFD >= 0 else { return "" }
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(masterFD, &bytes, bytes.count)
            if count > 0 { output.append(contentsOf: bytes[..<count]) }
            else { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func statuslineFileNames(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.filter { $0.hasPrefix("statusline-") })
    }

    private func newestStatusline(in directory: URL, excluding existingFiles: Set<String>) -> ClaudeObservation? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var newest: ClaudeObservation?
        for file in files where file.lastPathComponent.hasPrefix("statusline-") && !existingFiles.contains(file.lastPathComponent) {
            guard let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let observedAt = attributes.contentModificationDate,
                  let data = try? Data(contentsOf: file),
                  let observation = try? ClaudePayload.statusline(data, observedAt: observedAt) else { continue }
            if newest == nil || observedAt > newest!.observedAt { newest = observation }
        }
        return newest
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
}
