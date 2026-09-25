import Foundation
import Darwin

struct CodexProcessConfiguration: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

private final class RunningCodex: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var stopping = false

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning, !stopping else { return }
        stopping = true
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

struct CodexProcess: CodexTransport {
    let executablePath: String?
    let inheritedEnvironment: [String: String]
    let timeoutSeconds: Double?

    init(
        executablePath: String? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Double? = nil
    ) {
        self.executablePath = executablePath
        self.inheritedEnvironment = inheritedEnvironment
        self.timeoutSeconds = timeoutSeconds
    }

    static func configuration(
        account: AccountID,
        executablePath: String,
        inheritedEnvironment: [String: String]
    ) -> CodexProcessConfiguration {
        var environment = inheritedEnvironment
        environment["CODEX_HOME"] = account.directory
        return CodexProcessConfiguration(
            executablePath: executablePath,
            arguments: ["-s", "read-only", "-a", "never", "app-server"],
            environment: environment
        )
    }

    func read(account: AccountID) async throws -> (Data, Data) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: account.directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProbeFailure.permanent("Codex directory does not exist")
        }
        guard let executable = executablePath ?? Self.findCodex(in: inheritedEnvironment) else {
            throw ProbeFailure.permanent("Codex executable not found")
        }
        let policy = try ProbePolicy.bundled()
        let configuration = Self.configuration(
            account: account, executablePath: executable, inheritedEnvironment: inheritedEnvironment
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let owner = RunningCodex(process)

        do {
            try process.run()
        } catch {
            throw ProbeFailure.permanent("Codex could not start")
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds ?? policy.attemptTimeoutSeconds))
            if !Task.isCancelled { owner.terminate() }
        }
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            owner.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                _ = Darwin.usleep(20_000)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }

        return try await withTaskCancellationHandler {
            var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
            try Self.write(Self.initialize, to: input.fileHandleForWriting)
            _ = try await Self.readResponse(id: 1, from: &lines)
            try Self.write(Self.initialized, to: input.fileHandleForWriting)
            try Self.write(Self.accountRead, to: input.fileHandleForWriting)
            let accountData = try await Self.readResponse(id: 2, from: &lines)
            try Self.write(Self.rateLimitsRead, to: input.fileHandleForWriting)
            let limitsData = try await Self.readResponse(id: 3, from: &lines)
            return (accountData, limitsData)
        } onCancel: {
            owner.terminate()
        }
    }

    private static func findCodex(in environment: [String: String]) -> String? {
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in search {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func write(_ line: String, to file: FileHandle) throws {
        try file.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func readResponse<I: AsyncIteratorProtocol>(
        id: Int, from lines: inout I
    ) async throws -> Data where I.Element == String {
        while let line = try await lines.next() {
            guard let bytes = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let received = object["id"] as? Int else { continue }
            if received == id { return bytes }
        }
        throw ProbeFailure.transient("Codex app-server closed without a response")
    }

    private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"capbar","title":"CapBar","version":"0.1.0"}}}"#
    private static let initialized = #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#
    private static let accountRead = #"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{"refreshToken":false}}"#
    private static let rateLimitsRead = #"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}"#
}
