import Foundation
@testable import CapBarCore

@MainActor func runClaudeLiveChecks() async {
    let directory = ProcessInfo.processInfo.environment["CAPBAR_LIVE_CLAUDE_DIR"] ?? "~/.claude-work"
    let account = AccountID(provider: .claude, directory: directory)
    let terminal = ClaudeTerminalProcess(statuslineTimeoutSeconds: 20)
    do {
        let identity = try await ClaudeIdentityCLI().identity(account: account)
        try await terminal.start(account: account)
        let statusline = try await terminal.converse()
        let oauth = try await ClaudeOAuthClient().quota(account: account)
        await terminal.exit()
        await terminal.terminate()
        let snapshot = try ClaudeObservation.select(statusline, oauth, identity: identity, capturedAt: Date())
        check(statusline?.windows.isEmpty == false, "live Claude prompt yields statusline quota")
        check(oauth?.windows.isEmpty == false, "live Claude OAuth query yields quota")
        check(!snapshot.windows.isEmpty, "live Claude probe returns at least one quota window")
    } catch {
        await terminal.terminate()
        check(false, "live Claude probe should succeed: \(error)")
    }
}

private struct FakeCredentialReader: ClaudeCredentialReading {
    func read(service: String) throws -> Data? {
        Data(#"{"claudeAiOauth":{"accessToken":"fake-oauth-token"}}"#.utf8)
    }
}

private actor FakeClaudeHTTP: ClaudeHTTPTransport {
    private var received: URLRequest?
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        received = request
        let body = Data(#"{"five_hour":{"utilization":28,"resets_at":"2027-01-01T00:00:00Z"}}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func request() -> URLRequest? { received }
}

private actor ClaudeEventLog {
    private var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private final class ClaudeFactoryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    let observation: ClaudeObservation
    init(observation: ClaudeObservation) { self.observation = observation }
    func make() -> any ClaudeTerminalSession {
        lock.lock(); value += 1; lock.unlock()
        return FakeClaudeTerminal(log: ClaudeEventLog(), result: observation)
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct FakeClaudeTerminal: ClaudeTerminalSession {
    let log: ClaudeEventLog
    let result: ClaudeObservation?
    func start(account: AccountID) async throws { await log.record("start") }
    func converse() async throws -> ClaudeObservation? {
        await log.record("prompt/statusline")
        return result
    }
    func exit() async { await log.record("exit") }
    func terminate() async { await log.record("terminate") }
}

private struct FakeClaudeOAuth: ClaudeOAuthQuery {
    let log: ClaudeEventLog
    let result: ClaudeObservation?
    func quota(account: AccountID) async throws -> ClaudeObservation? {
        await log.record("oauth")
        return result
    }
}

private struct FailingClaudeOAuth: ClaudeOAuthQuery {
    func quota(account: AccountID) async throws -> ClaudeObservation? {
        throw ProbeFailure.transient("fake network failure")
    }
}

private struct FailingClaudeTerminal: ClaudeTerminalSession {
    func start(account: AccountID) async throws {}
    func converse() async throws -> ClaudeObservation? { throw ProbeFailure.transient("fake statusline failure") }
    func exit() async {}
    func terminate() async {}
}

private struct FakeClaudeIdentity: ClaudeIdentityQuery {
    func identity(account: AccountID) async throws -> AccountIdentity {
        AccountIdentity(email: "fake@example.com", plan: "team", organization: "Example")
    }
}

@MainActor func runClaudeClientChecks() async {
    let id = AccountID(provider: .claude, directory: "~/.claude")
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    do {
        let status = ClaudeObservation(windows: [.fiveHour: try QuotaWindow(kind: .fiveHour, remainingPercent: 70, resetsAt: nil)], observedAt: time)
        let oauth = ClaudeObservation(windows: [.fiveHour: try QuotaWindow(kind: .fiveHour, remainingPercent: 69, resetsAt: nil)], observedAt: time.addingTimeInterval(1))
        let log = ClaudeEventLog()
        let client = ClaudeClient(
            terminalFactory: { FakeClaudeTerminal(log: log, result: status) },
            oauth: FakeClaudeOAuth(log: log, result: oauth),
            identity: FakeClaudeIdentity(),
            now: { time.addingTimeInterval(2) }
        )
        let snapshot = try await client.probe(account: id)
        check(snapshot.windows.first?.remainingPercent == 69, "later OAuth observation is selected")
        check(await log.snapshot() == ["start", "prompt/statusline", "oauth", "exit", "terminate"], "one prompt then statusline then OAuth then exit")

        let statusOnly = ClaudeClient(terminalFactory: { FakeClaudeTerminal(log: ClaudeEventLog(), result: status) }, oauth: FakeClaudeOAuth(log: ClaudeEventLog(), result: nil), identity: FakeClaudeIdentity(), now: { time })
        check(try await statusOnly.probe(account: id).windows.count == 1, "statusline alone succeeds")
        let oauthOnly = ClaudeClient(terminalFactory: { FakeClaudeTerminal(log: ClaudeEventLog(), result: nil) }, oauth: FakeClaudeOAuth(log: ClaudeEventLog(), result: oauth), identity: FakeClaudeIdentity(), now: { time })
        check(try await oauthOnly.probe(account: id).windows.count == 1, "OAuth alone succeeds")
        let networkFailed = ClaudeClient(terminalFactory: { FakeClaudeTerminal(log: ClaudeEventLog(), result: status) }, oauth: FailingClaudeOAuth(), identity: FakeClaudeIdentity(), now: { time })
        check(try await networkFailed.probe(account: id).windows.count == 1, "statusline survives OAuth transport failure")
        let terminalFailed = ClaudeClient(terminalFactory: { FailingClaudeTerminal() }, oauth: FakeClaudeOAuth(log: ClaudeEventLog(), result: oauth), identity: FakeClaudeIdentity(), now: { time })
        check(try await terminalFailed.probe(account: id).windows.count == 1, "OAuth survives terminal statusline failure")
        let missing = ClaudeClient(terminalFactory: { FakeClaudeTerminal(log: ClaudeEventLog(), result: nil) }, oauth: FakeClaudeOAuth(log: ClaudeEventLog(), result: nil), identity: FakeClaudeIdentity(), now: { time })
        do {
            _ = try await missing.probe(account: id)
            check(false, "both missing channels fail")
        } catch {
            check(true, "both missing channels fail")
        }
        let count = ClaudeFactoryCount(observation: status)
        let concurrent = ClaudeClient(terminalFactory: { count.make() }, oauth: FakeClaudeOAuth(log: ClaudeEventLog(), result: nil), identity: FakeClaudeIdentity(), now: { time })
        async let first = concurrent.probe(account: id)
        async let second = concurrent.probe(account: AccountID(provider: .claude, directory: "~/.claude-other"))
        _ = try await (first, second)
        check(count.count() == 2, "parallel accounts receive separate Claude terminal sessions")

        let http = FakeClaudeHTTP()
        let realOAuthShape = ClaudeOAuthClient(credentials: ClaudeCredentialLoader(reader: FakeCredentialReader()), http: http, now: { time })
        let fetched = try await realOAuthShape.quota(account: id)
        check(fetched?.windows[.fiveHour]?.remainingPercent == 72, "OAuth HTTP response converts utilization")
        let request = await http.request()
        check(request?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage", "OAuth requests the usage endpoint")
        check(request?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-oauth-token", "OAuth passes the loaded token only in the header")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fakeClaude = temporary.appendingPathComponent("fake-claude")
        let script = #"""
#!/usr/bin/python3
import json, os, sys
assert sys.argv[1:] == ['auth', 'status', '--json']
assert 'ANTHROPIC_API_KEY' not in os.environ
assert 'CLAUDE_CODE_OAUTH_TOKEN' not in os.environ
print(json.dumps({'loggedIn': True, 'email': 'fake@example.com', 'subscriptionType': 'team', 'orgName': os.getenv('CLAUDE_CONFIG_DIR', 'default')}))
"""#
        try Data(script.utf8).write(to: fakeClaude)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path)
        let identityCLI = ClaudeIdentityCLI(executablePath: fakeClaude.path, inheritedEnvironment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/wrong", "ANTHROPIC_API_KEY": "wrong", "CLAUDE_CODE_OAUTH_TOKEN": "wrong"], timeoutSeconds: 1)
        check(try await identityCLI.identity(account: id).organization == "default", "default profile leaves CLAUDE_CONFIG_DIR unset")
        let customID = AccountID(provider: .claude, directory: temporary.path)
        check(try await identityCLI.identity(account: customID).organization == customID.directory, "custom profile sets CLAUDE_CONFIG_DIR")
        let onPath = temporary.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: fakeClaude, to: onPath)
        let discovered = ClaudeIdentityCLI(executablePath: nil, inheritedEnvironment: ["PATH": temporary.path], timeoutSeconds: 1)
        check(try await discovered.identity(account: id).email == "fake@example.com", "Claude executable is found from PATH")

        let fakeInteractive = temporary.appendingPathComponent("fake-interactive-claude")
        let terminalScript = #"""
#!/usr/bin/python3
import json, os, subprocess, sys
size = os.get_terminal_size()
assert size.columns >= 100 and size.lines >= 30
args = sys.argv[1:]
assert '--restricted' in args and '--strict-mcp-config' in args
assert args[args.index('--tools') + 1] == ''
settings = json.loads(args[args.index('--settings') + 1])
print('Quick\x1b[2m safety\x1b[0m check: trust\x1b[2m this\x1b[0m folder?', flush=True)
sys.stdin.readline()
print('READY', flush=True)
prompt = sys.stdin.readline()
assert 'Reply with exactly OK' in prompt
subprocess.run(settings['statusLine']['command'], input=json.dumps({'rate_limits': {'five_hour': {'used_percentage': 30, 'resets_at': 1800600000}}}), shell=True, text=True, check=True)
print('OK', flush=True)
assert sys.stdin.readline().strip() == '/exit'
with open(os.environ['CAPBAR_FAKE_EXIT_LOG'], 'w') as log:
    log.write('exited')
"""#
        try Data(terminalScript.utf8).write(to: fakeInteractive)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeInteractive.path)
        let exitLog = temporary.appendingPathComponent("fake-exit.txt")
        let terminal = ClaudeTerminalProcess(executablePath: fakeInteractive.path, inheritedEnvironment: ["PATH": "/usr/bin:/bin", "CAPBAR_FAKE_EXIT_LOG": exitLog.path], temporaryRoot: temporary, statuslineTimeoutSeconds: 3)
        try await terminal.start(account: id)
        let terminalStatus = try await terminal.converse()
        check(terminalStatus?.windows[.fiveHour]?.remainingPercent == 70, "PTY session captures fresh statusline after one prompt")
        await terminal.exit()
        check(FileManager.default.fileExists(atPath: exitLog.path), "PTY session sends /exit after statusline")
        await terminal.terminate()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        check(!leftovers.contains { $0.hasPrefix("capbar-claude-") }, "terminal temporary workspace is removed")

        let staleExecutable = temporary.appendingPathComponent("fake-stale-claude")
        let staleScript = #"""
#!/usr/bin/python3
import json, subprocess, sys, time
args = sys.argv[1:]
settings = json.loads(args[args.index('--settings') + 1])
subprocess.run(settings['statusLine']['command'], input=json.dumps({'rate_limits': {'five_hour': {'used_percentage': 90}}}), shell=True, text=True, check=True)
print('READY', flush=True)
sys.stdin.readline()
time.sleep(0.6)
sys.stdin.readline()
"""#
        try Data(staleScript.utf8).write(to: staleExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staleExecutable.path)
        let staleTerminal = ClaudeTerminalProcess(executablePath: staleExecutable.path, inheritedEnvironment: ["PATH": "/usr/bin:/bin"], temporaryRoot: temporary, statuslineTimeoutSeconds: 0.3)
        try await staleTerminal.start(account: id)
        let staleResult = try await staleTerminal.converse()
        check(staleResult?.windows.isEmpty != false, "pre-prompt statusline is not accepted as refreshed quota")
        await staleTerminal.exit()
        await staleTerminal.terminate()
    } catch {
        check(false, "Claude client fake scenario should pass: \(error)")
    }
}
