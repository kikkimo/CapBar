import Foundation
import CryptoKit
import Darwin

protocol ClaudeCredentialReading: Sendable {
    func read(service: String) throws -> Data?
}

/// Uses the same system command used by the verified local OAuth probes.
/// No credential text is passed in arguments or included in errors.
struct SecurityCLIReader: ClaudeCredentialReading {
    let executablePath: String
    let timeoutSeconds: TimeInterval

    init(executablePath: String = "/usr/bin/security", timeoutSeconds: TimeInterval = 8) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
    }

    func read(service: String) throws -> Data? {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw ProbeFailure.permanent("Invalid credential read timeout")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProbeFailure.permanent("Claude credential reader could not start")
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            throw ProbeFailure.transient("Claude credential lookup timed out")
        }
        if process.terminationStatus == 44 { return nil }
        guard process.terminationStatus == 0 else {
            throw ProbeFailure.permanent("Claude credential is unavailable")
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}

struct ClaudeCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let expiresAtMilliseconds: Double?

    var description: String { "ClaudeCredential(redacted)" }
    var debugDescription: String { description }
}

struct ClaudeCredentialLoader: Sendable {
    let reader: any ClaudeCredentialReading

    init(reader: any ClaudeCredentialReading = SecurityCLIReader()) {
        self.reader = reader
    }

    static func serviceName(for account: AccountID) -> String {
        let defaultDirectory = AccountID(provider: .claude, directory: "~/.claude").directory
        if account.directory == defaultDirectory { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(account.directory.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + prefix
    }

    func load(account: AccountID) throws -> ClaudeCredential {
        guard account.provider == .claude else { throw ProbeFailure.permanent("Wrong provider") }
        guard let data = try reader.read(service: Self.serviceName(for: account)),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProbeFailure.permanent("Claude OAuth credential was not found")
        }
        let expiration: Double?
        if let number = oauth["expiresAt"] as? NSNumber {
            expiration = number.doubleValue
        } else if let text = oauth["expiresAt"] as? String {
            expiration = Double(text)
        } else {
            expiration = nil
        }
        return ClaudeCredential(
            accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAtMilliseconds: expiration
        )
    }
}
