import Foundation
import Darwin
@testable import CapBarCore

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
    return try Data(contentsOf: url)
}

@MainActor func runCodexLiveChecks() async {
    do {
        let snapshot = try await CodexClient().probe(account: AccountID(provider: .codex, directory: "~/.codex"))
        check(!snapshot.windows.isEmpty, "local Codex account returns at least one quota window")
    } catch {
        check(false, "local Codex read-only probe should succeed: \(error)")
    }
}

private struct FixtureCodexTransport: CodexTransport {
    let accountData: Data
    let limitsData: Data
    func read(account: AccountID) async throws -> (Data, Data) { (accountData, limitsData) }
}

@MainActor func runCodexClientChecks() async {
    do {
        let weekly = try CodexPayload.decodeRateLimits(fixture("codex-weekly-only.json"))
        check(weekly.count == 1 && weekly[0].kind == .sevenDay, "weekly-only primary does not invent five-hour window")
        check(weekly[0].remainingPercent == 21, "used percent converts to remaining percent")
        check(weekly[0].resetsAt == Date(timeIntervalSince1970: 1_800_600_000), "reset timestamp uses Unix seconds")

        let both = try CodexPayload.decodeRateLimits(fixture("codex-two-windows.json"))
        check(both.count == 2, "both known durations are retained")
        check(both.first { $0.kind == .fiveHour }?.remainingPercent == 75, "codex metered bucket wins over unrelated buckets")
        check(both.first { $0.kind == .sevenDay }?.remainingPercent == 25, "weekly percentage is independent")

        let oldShape = Data(#"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1800010000},"secondary":null}}}"#.utf8)
        check(try CodexPayload.decodeRateLimits(oldShape).first?.remainingPercent == 90, "legacy single-bucket response remains supported")
        checkThrows("JSON-RPC error fails") { _ = try CodexPayload.decodeRateLimits(fixture("codex-error.json")) }
        let account = try CodexPayload.decodeAccount(fixture("codex-account.json"))
        check(account.email == nil && account.plan == "team", "account identity allows null email")

        let id = AccountID(provider: .codex, directory: "~/.codex-other")
        let launch = CodexProcess.configuration(account: id, executablePath: "/usr/local/bin/codex", inheritedEnvironment: ["PATH": "/usr/bin"])
        check(launch.environment["CODEX_HOME"] == id.directory, "custom Codex directory is applied to child process")
        check(launch.arguments == ["-s", "read-only", "-a", "never", "app-server"], "child process is read-only and approval-free")

        let client = CodexClient(transport: FixtureCodexTransport(accountData: try fixture("codex-account.json"), limitsData: try fixture("codex-weekly-only.json")), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let snapshot = try await client.probe(account: id)
        check(snapshot.identity.plan == "team", "probe combines account identity with limits")
        check(snapshot.windows.count == 1, "probe returns only available window")
        check(snapshot.capturedAt == Date(timeIntervalSince1970: 1_800_000_000), "probe records collection time")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("fake-codex")
        let log = temporary.appendingPathComponent("rpc-methods.txt")
        let script = #"""
#!/usr/bin/python3
import json, os, sys
with open(os.environ['CAPBAR_FAKE_LOG'], 'w') as log:
    for line in sys.stdin:
        request = json.loads(line)
        method = request['method']
        log.write(method + '\n')
        log.flush()
        if method == 'initialize':
            print(json.dumps({'id': 1, 'result': {}}), flush=True)
        elif method == 'account/read':
            print(json.dumps({'id': 2, 'result': {'account': {'type': 'chatgpt', 'email': 'fake@example.com', 'planType': 'plus'}}}), flush=True)
        elif method == 'account/rateLimits/read':
            print(json.dumps({'id': 3, 'result': {'rateLimits': {'primary': {'usedPercent': 20, 'windowDurationMins': 10080, 'resetsAt': 1800600000}}}}), flush=True)
"""#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let fakeID = AccountID(provider: .codex, directory: temporary.path)
        let process = CodexProcess(executablePath: executable.path, inheritedEnvironment: ["PATH": "/usr/bin:/bin", "CAPBAR_FAKE_LOG": log.path])
        let (fakeAccount, fakeLimits) = try await process.read(account: fakeID)
        check(try CodexPayload.decodeAccount(fakeAccount).email == "fake@example.com", "real stdio transport reads account response")
        check(try CodexPayload.decodeRateLimits(fakeLimits).first?.remainingPercent == 80, "real stdio transport reads limits response")
        let methods = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        check(methods == ["initialize", "initialized", "account/read", "account/rateLimits/read"], "one process performs ordered handshake and both reads")

        let stubborn = temporary.appendingPathComponent("stubborn-codex")
        let pidFile = temporary.appendingPathComponent("stubborn-pid.txt")
        let stubbornScript = #"""
#!/usr/bin/python3
import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ['CAPBAR_FAKE_LOG'], 'w') as output:
    output.write(str(os.getpid()))
while True:
    time.sleep(1)
"""#
        try Data(stubbornScript.utf8).write(to: stubborn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stubborn.path)
        let start = Date()
        // Allow the Python fixture to start even when the full suite is building concurrently.
        let timeoutProcess = CodexProcess(executablePath: stubborn.path, inheritedEnvironment: ["PATH": "/usr/bin:/bin", "CAPBAR_FAKE_LOG": pidFile.path], timeoutSeconds: 1)
        do {
            _ = try await timeoutProcess.read(account: fakeID)
            check(false, "unresponsive app-server must time out")
        } catch {
            check(Date().timeIntervalSince(start) < 3, "timeout ends an unresponsive app-server promptly")
        }
        if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
            check(Darwin.kill(Int32(pid), 0) == -1, "stubborn timed-out child is not left running")
        } else {
            check(false, "stubborn fixture started before the timeout")
        }
    } catch {
        check(false, "Codex fixtures should parse: \(error)")
    }
}
