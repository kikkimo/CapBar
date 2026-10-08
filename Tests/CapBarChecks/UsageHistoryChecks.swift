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

    do {
        let cacheURL = folder.appendingPathComponent("historical-cache.sqlite3")
        let cacheStore = UsageHistoryStore(url: cacheURL)
        let account = AccountID(provider: .claude, directory: folder.appendingPathComponent("history-account").path)
        let calibration = [HistoricalAccount(account: account, tier: .claudePro)]
        let base = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!
        let farReset = base.addingTimeInterval(30 * 86_400)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func snapshot(_ index: Int, used: Double) throws -> UsageSnapshot {
            UsageSnapshot(identity: identity,
                          windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 100 - used,
                                                    resetsAt: farReset)],
                          capturedAt: base.addingTimeInterval(Double(index) * 8 * 3_600))
        }
        for index in 0...21 {
            _ = try await cacheStore.append(account: account, snapshot: snapshot(index, used: Double(index * 2)),
                                            planTier: .claudePro)
        }
        let first = try await cacheStore.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
        check(first?.fromCache == false && first?.statistics.highSevenDays?.usedPercent == 42,
              "first all-time lookup calculates and stores seven complete days")
        let second = try await cacheStore.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
        check(second?.fromCache == true && second?.statistics.highSevenDays?.usedPercent == 42,
              "unchanged history reuses persisted SQLite statistics")
        var cacheDatabase: OpaquePointer?
        if sqlite3_open(cacheURL.path, &cacheDatabase) == SQLITE_OK, let cacheDatabase {
            let downgradeSignature = #"UPDATE history_statistics_cache SET signature = REPLACE(signature, '"version":4', '"version":3')"#
            check(sqlite3_exec(cacheDatabase, downgradeSignature, nil, nil, nil) == SQLITE_OK,
                  "legacy summary signature fixture updates")
            sqlite3_close(cacheDatabase)
            let rebuilt = try await cacheStore.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
            check(rebuilt?.fromCache == false && rebuilt?.statistics.highSevenDays?.usedPercent == 42,
                  "an older calculation version invalidates cached historical records")
        } else {
            if let cacheDatabase { sqlite3_close(cacheDatabase) }
            check(false, "historical cache fixture opens for version migration")
        }
        _ = try await cacheStore.append(account: account, snapshot: snapshot(21, used: 42), planTier: .claudePro)
        let unchanged = try await cacheStore.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
        check(unchanged?.fromCache == true, "identical upsert does not invalidate the summary")
        _ = try await cacheStore.append(account: account, snapshot: snapshot(21, used: 43), planTier: .claudePro)
        let corrected = try await cacheStore.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
        check(corrected?.fromCache == false && corrected?.statistics.highSevenDays?.usedPercent == 43,
              "same-timestamp correction invalidates and rebuilds persisted records")
        let reopened = UsageHistoryStore(url: cacheURL)
        let restored = try await reopened.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
        check(restored?.fromCache == true && restored?.statistics.highSevenDays?.usedPercent == 43,
              "summary cache survives a store restart")
        _ = try await cacheStore.append(account: account, snapshot: snapshot(21, used: 44), planTier: .claudePro)
        let externalChange = try await reopened.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: utc)
        check(externalChange?.fromCache == false && externalChange?.statistics.highSevenDays?.usedPercent == 44,
              "another store instance's write invalidates the persisted cache")
        let anotherTier = try await reopened.historicalStatistics(
            accounts: [HistoricalAccount(account: account, tier: .claudeMax5)], intervalHours: 8, calendar: utc)
        check(anotherTier?.fromCache == false, "subscription calibration changes invalidate the cache")
        let anotherInterval = try await reopened.historicalStatistics(accounts: calibration, intervalHours: 4, calendar: utc)
        check(anotherInterval?.fromCache == false, "sampling interval changes invalidate the cache")
        var local = utc
        local.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let anotherZone = try await reopened.historicalStatistics(accounts: calibration, intervalHours: 8, calendar: local)
        check(anotherZone?.fromCache == false, "local calendar time zone changes invalidate day boundaries")
        let secondAccount = AccountID(provider: .claude, directory: folder.appendingPathComponent("history-max-account").path)
        for index in 0...21 {
            _ = try await reopened.append(account: secondAccount, snapshot: snapshot(index, used: Double(index)),
                                          planTier: .claudeMax5)
        }
        let combined = try await reopened.historicalStatistics(
            accounts: calibration + [HistoricalAccount(account: secondAccount, tier: .claudeMax5)],
            intervalHours: 8, calendar: utc
        )
        check(combined?.fromCache == false && combined?.statistics.highSevenDays?.usedPercent == 149,
              "all-time provider records convert historical Max usage into the first Pro account's capacity")
        let missingBaseline = HistoricalAccount(
            account: AccountID(provider: .claude, directory: folder.appendingPathComponent("history-empty-account").path),
            tier: .claudePro
        )
        let observedSecond = try await reopened.historicalStatistics(
            accounts: [missingBaseline, HistoricalAccount(account: secondAccount, tier: .claudeMax5)],
            intervalHours: 8, calendar: utc
        )
        check(observedSecond?.statistics.highSevenDays?.usedPercent == 105
              && observedSecond?.statistics.highInterval?.usedPercent == 5,
              "historical statistics include observed accounts when the first account has no samples")
    } catch {
        check(false, "historical cache checks should complete: \(error)")
    }
}
