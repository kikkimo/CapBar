import Foundation
import Darwin

struct ClaudeIdentityCLI: ClaudeIdentityQuery {
    let executablePath: String?
    let inheritedEnvironment: [String: String]
    let timeoutSeconds: TimeInterval

    init(
        executablePath: String? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: TimeInterval = 10
    ) {
        self.executablePath = executablePath
        self.inheritedEnvironment = inheritedEnvironment
        self.timeoutSeconds = timeoutSeconds
    }

    func identity(account: AccountID) async throws -> AccountIdentity {
        guard account.provider == .claude else { throw ProbeFailure.permanent("Wrong provider") }
        return try await Task.detached(priority: .utility) {
            try read(account: account)
        }.value
    }

    private func read(account: AccountID) throws -> AccountIdentity {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw ProbeFailure.permanent("Invalid Claude identity timeout")
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

        let process = Process()
        guard let executable = executablePath ?? Self.findClaude(in: inheritedEnvironment) else {
            throw ProbeFailure.permanent("Claude executable not found")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status", "--json"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProbeFailure.permanent("Claude executable could not start")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ProbeFailure.transient("Claude identity query timed out")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProbeFailure.permanent("Claude is not signed in")
        }
        return try ClaudePayload.authStatus(output.fileHandleForReading.readDataToEndOfFile())
    }

    static func findClaude(in environment: [String: String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("claude").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
