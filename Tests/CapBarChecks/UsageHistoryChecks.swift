import Foundation
import SQLite3
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
        check(try await store.append(account: first, snapshot: firstSnapshot, planTier: .claudeTeamPremium),
              "seven-day quota and detected tier are recorded together")
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
        check(all.first?.planTier == .claudeTeamPremium,
              "history retains subscription tier at sampling time for later weighted totals")
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

    do {
        let legacyURL = folder.appendingPathComponent("legacy-history.sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open(legacyURL.path, &database) == SQLITE_OK, let database else {
            check(false, "legacy database fixture opens")
            return
        }
        let legacySchema = """
            CREATE TABLE usage_samples (
                provider TEXT NOT NULL, directory TEXT NOT NULL, captured_at REAL NOT NULL,
                used_percent REAL NOT NULL, resets_at REAL,
                PRIMARY KEY (provider, directory, captured_at)
            ) WITHOUT ROWID;
            """
        check(sqlite3_exec(database, legacySchema, nil, nil, nil) == SQLITE_OK,
              "legacy history fixture creates its original schema")
        var insert: OpaquePointer?
        if sqlite3_prepare_v2(database, "INSERT INTO usage_samples VALUES (?, ?, ?, ?, NULL)", -1, &insert, nil) == SQLITE_OK,
           let insert {
            let inserted = "claude".withCString { provider in
                first.directory.withCString { directory in
                    sqlite3_bind_text(insert, 1, provider, -1, nil)
                    sqlite3_bind_text(insert, 2, directory, -1, nil)
                    sqlite3_bind_double(insert, 3, start.addingTimeInterval(-60).timeIntervalSince1970)
                    sqlite3_bind_double(insert, 4, 13)
                    return sqlite3_step(insert) == SQLITE_DONE
                }
            }
            check(inserted, "legacy history fixture has an existing sample")
            sqlite3_finalize(insert)
        } else {
            check(false, "legacy history insert prepares")
        }
        sqlite3_close(database)
        let legacyStore = UsageHistoryStore(url: legacyURL)
        let legacySnapshot = UsageSnapshot(
            identity: identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 45, resetsAt: reset)],
            capturedAt: start
        )
        check(try await legacyStore.append(account: first, snapshot: legacySnapshot, planTier: .claudeTeamStandard),
              "existing database adds a plan tier column without reset")
        let migrated = try await legacyStore.samples(account: first, from: start.addingTimeInterval(-61), through: start.addingTimeInterval(1))
        check(migrated.count == 2 && migrated[0].usedPercent == 13 && migrated[0].planTier == nil
              && migrated[1].usedPercent == 55 && migrated[1].planTier == .claudeTeamStandard,
              "migration preserves existing samples and records new tier values")
    } catch {
        check(false, "legacy history migration should work: \(error)")
    }
}
