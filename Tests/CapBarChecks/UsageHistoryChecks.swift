import Foundation
@testable import CapBarCore

@MainActor func runUsageHistoryChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("usage-history.sqlite3")
    let first = AccountID(provider: .claude, directory: folder.appendingPathComponent("claude-a").path)
    let second = AccountID(provider: .codex, directory: folder.appendingPathComponent("codex-b").path)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(86_400)
    let identity = AccountIdentity(email: "private-example@example.com", plan: "Team", organization: "Example")
    let store = UsageHistoryStore(url: databaseURL)

    do {
        let firstSnapshot = UsageSnapshot(
            identity: identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 70, resetsAt: reset)],
            capturedAt: start
        )
        check(try await store.append(account: first, snapshot: firstSnapshot), "seven-day quota is recorded")
        check(try await store.append(account: first, snapshot: firstSnapshot), "same-time write is idempotent")
        let revised = UsageSnapshot(
            identity: identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 68, resetsAt: reset)],
            capturedAt: start
        )
        check(try await store.append(account: first, snapshot: revised), "same-time correction is accepted")
        let other = UsageSnapshot(
            identity: identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 80, resetsAt: reset)],
            capturedAt: start
        )
        check(try await store.append(account: second, snapshot: other), "second account can share a capture time")
        let noWeekly = UsageSnapshot(identity: identity, windows: [], capturedAt: start.addingTimeInterval(60))
        check(try await store.append(account: first, snapshot: noWeekly) == false, "missing seven-day window writes no sample")

        let all = try await store.samples(account: first, from: start.addingTimeInterval(-1), through: start.addingTimeInterval(60))
        check(all.count == 1, "same account and timestamp have one historical row")
        check(all.first?.usedPercent == 32, "history stores seven-day used percentage")
        check(all.first?.capturedAt == start && all.first?.resetsAt == reset, "UTC capture and reset timestamps round trip")
        let otherRows = try await store.samples(account: second, from: start.addingTimeInterval(-1), through: start.addingTimeInterval(60))
        check(otherRows.count == 1 && otherRows.first?.usedPercent == 20, "history keeps accounts separate")
        let tooEarly = try await store.samples(account: first, from: start.addingTimeInterval(-60), through: start.addingTimeInterval(-1))
        check(tooEarly.isEmpty, "time range excludes newer samples")

        let mode = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "history database is private to current user")
        let bytes = try Data(contentsOf: databaseURL)
        check(!String(decoding: bytes, as: UTF8.self).contains("private-example@example.com"), "history does not persist account email")
    } catch {
        check(false, "history store should work: \(error)")
    }
}
