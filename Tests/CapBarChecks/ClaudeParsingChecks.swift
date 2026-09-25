import Foundation
@testable import CapBarCore

private func claudeFixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name))
}

@MainActor func runClaudeParsingChecks() {
    do {
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let later = earlier.addingTimeInterval(10)
        let status = try ClaudePayload.statusline(claudeFixture("claude-statusline.json"), observedAt: earlier)
        let oauth = try ClaudePayload.oauth(claudeFixture("claude-oauth.json"), observedAt: later)
        check(status.windows[.fiveHour]?.remainingPercent == 65.5, "statusline used percentage becomes remaining")
        check(status.windows[.sevenDay]?.remainingPercent == 22, "statusline seven-day value is independent")
        check(oauth.windows[.fiveHour]?.remainingPercent == 65, "OAuth utilization zero-to-100 is used percentage")
        check(oauth.windows[.sevenDay]?.remainingPercent == 21, "OAuth seven-day utilization converts separately")
        check(oauth.windows[.fiveHour]?.resetsAt != nil, "OAuth fractional ISO reset parses")
        check(oauth.windows[.sevenDay]?.resetsAt != nil, "OAuth whole-second ISO reset parses")

        let identity = try ClaudePayload.authStatus(claudeFixture("claude-auth-status.json"))
        check(identity.email == "person@example.com" && identity.organization == "Example Team", "identity reads email and organization")
        check(identity.plan == "team", "identity reads detected subscription")
        let merged = try ClaudeObservation.select(status, oauth, identity: identity, capturedAt: later)
        check(merged.windows.first { $0.kind == .fiveHour }?.remainingPercent == 65, "later OAuth wins per window")
        check(merged.windows.first { $0.kind == .sevenDay }?.remainingPercent == 21, "later OAuth weekly window wins")
        check(merged.windows.count == 2, "each window displays one selected value")

        let weeklyOnly = Data(#"{"rate_limits":{"seven_day":{"used_percentage":99,"resets_at":1800600000}}}"#.utf8)
        let weeklyStatus = try ClaudePayload.statusline(weeklyOnly, observedAt: later)
        check(weeklyStatus.windows[.fiveHour] == nil && weeklyStatus.windows[.sevenDay]?.remainingPercent == 1, "missing five-hour window is not invented")
        let fallback = try ClaudeObservation.select(weeklyStatus, nil, identity: identity, capturedAt: later)
        check(fallback.windows.count == 1, "statusline alone succeeds")
        let oauthOnly = try ClaudeObservation.select(nil, oauth, identity: identity, capturedAt: later)
        check(oauthOnly.windows.count == 2, "OAuth alone succeeds")
        checkThrows("no valid source fails") { _ = try ClaudeObservation.select(nil, nil, identity: identity, capturedAt: later) }
        let zeroAndFull = Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":100}}"#.utf8)
        let boundaries = try ClaudePayload.oauth(zeroAndFull, observedAt: later)
        check(boundaries.windows[.fiveHour]?.remainingPercent == 100, "zero utilization means full remaining")
        check(boundaries.windows[.sevenDay]?.remainingPercent == 0, "full utilization means empty remaining")
        let invalid = Data(#"{"five_hour":{"utilization":-1},"seven_day":{"utilization":120}}"#.utf8)
        check(try ClaudePayload.oauth(invalid, observedAt: later).windows.isEmpty, "out-of-range windows are discarded")

        let defaultID = AccountID(provider: .claude, directory: "~/.claude")
        let customID = AccountID(provider: .claude, directory: "/Users/example/.claude-work")
        check(ClaudeCredentialLoader.serviceName(for: defaultID) == "Claude Code-credentials", "default profile selects its service")
        check(ClaudeCredentialLoader.serviceName(for: customID) == "Claude Code-credentials-dd1118a7", "custom profile selects its service")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fakeSecurity = temporary.appendingPathComponent("fake-security")
        let script = #"""
#!/bin/sh
test "$#" -eq 4 && test "$1" = find-generic-password && test "$2" = -s && test "$3" = "Claude Code-credentials" && test "$4" = -w || exit 2
printf '%s\n' '{"claudeAiOauth":{"accessToken":"fake-tool-token"}}'
"""#
        try Data(script.utf8).write(to: fakeSecurity)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSecurity.path)
        let credential = try ClaudeCredentialLoader(reader: SecurityCLIReader(executablePath: fakeSecurity.path, timeoutSeconds: 1)).load(account: defaultID)
        check(credential.accessToken == "fake-tool-token", "bounded security command returns credential")
        check(!String(describing: credential).contains("fake-tool-token"), "credential description redacts token")
        let record = AccountRecord(id: defaultID, snapshot: nil, lastAttemptAt: nil, lastError: nil)
        let saved = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        check(!saved.contains(credential.accessToken), "snapshot JSON does not contain OAuth credential")

        let sleeper = temporary.appendingPathComponent("fake-slow-security")
        try Data("#!/usr/bin/python3\nimport time\ntime.sleep(5)\n".utf8).write(to: sleeper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let timeoutStarted = Date()
        checkThrows("security command times out") {
            _ = try SecurityCLIReader(executablePath: sleeper.path, timeoutSeconds: 0.1).read(service: "Claude Code-credentials")
        }
        check(Date().timeIntervalSince(timeoutStarted) < 2, "credential timeout returns without blocking cleanup")


    } catch {
        check(false, "Claude fixtures should parse: \(error)")
    }
}
