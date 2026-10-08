import Foundation
import SQLite3

struct UsageHistorySample: Sendable, Equatable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
    let planTier: UsagePlanTier?

    init(capturedAt: Date, usedPercent: Double, resetsAt: Date?, planTier: UsagePlanTier? = nil) {
        self.capturedAt = capturedAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.planTier = planTier
    }
}

enum UsageHistoryError: Error {
    case database(String)
}

struct HistoricalAccount: Codable, Sendable {
    let account: AccountID
    let tier: UsagePlanTier
}

struct HistoricalStatisticsLoad: Sendable {
    let statistics: HistoricalTrendStatistics
    let fromCache: Bool
}

private struct HistoricalCacheSignature: Codable {
    let version: Int
    let accounts: [HistoricalAccount]
    let intervalHours: Int
    let calendar: String
    let timeZone: String
}

actor UsageHistoryStore {
    private let url: URL

    init(url: URL = StorageSupport.appSupportURL("usage-history.sqlite3")) {
        self.url = url
    }

    func append(account: AccountID, snapshot: UsageSnapshot, planTier: UsagePlanTier? = nil) throws -> Bool {
        guard let weekly = snapshot.windows.first(where: { $0.kind == .sevenDay }) else { return false }
        try withDatabase { database in
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw error(database) }
            do {
                let sql = """
                    INSERT INTO usage_samples(provider, directory, captured_at, used_percent, resets_at, plan_tier)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, directory, captured_at) DO UPDATE SET
                        used_percent = excluded.used_percent,
                        resets_at = excluded.resets_at,
                        plan_tier = COALESCE(excluded.plan_tier, usage_samples.plan_tier)
                    WHERE usage_samples.used_percent IS NOT excluded.used_percent
                       OR usage_samples.resets_at IS NOT excluded.resets_at
                       OR (excluded.plan_tier IS NOT NULL AND usage_samples.plan_tier IS NOT excluded.plan_tier)
                    """
                let statement = try prepare(sql, in: database)
                defer { sqlite3_finalize(statement) }
                try bind(account.provider.rawValue, to: 1, in: statement, database: database)
                try bind(account.directory, to: 2, in: statement, database: database)
                sqlite3_bind_double(statement, 3, snapshot.capturedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, 100 - weekly.remainingPercent)
                if let reset = weekly.resetsAt {
                    sqlite3_bind_double(statement, 5, reset.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 5)
                }
                if let planTier {
                    try bind(planTier.rawValue, to: 6, in: statement, database: database)
                } else {
                    sqlite3_bind_null(statement, 6)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error(database) }
                if sqlite3_changes(database) > 0 {
                    let revision = try prepare("""
                        INSERT INTO history_account_revisions(provider, directory, revision) VALUES (?, ?, 1)
                        ON CONFLICT(provider, directory) DO UPDATE SET revision = revision + 1
                        """, in: database)
                    defer { sqlite3_finalize(revision) }
                    try bind(account.provider.rawValue, to: 1, in: revision, database: database)
                    try bind(account.directory, to: 2, in: revision, database: database)
                    guard sqlite3_step(revision) == SQLITE_DONE else { throw error(database) }
                }
                guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw error(database) }
            } catch {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
        return true
    }

    func historicalStatistics(accounts: [HistoricalAccount], intervalHours: Int,
                              calendar: Calendar) throws -> HistoricalStatisticsLoad? {
        guard let first = accounts.first, intervalHours > 0,
              accounts.allSatisfy({ $0.account.provider == first.account.provider && $0.tier.provider == first.account.provider })
        else { return nil }
        let signatureEncoder = JSONEncoder()
        signatureEncoder.outputFormatting = [.sortedKeys]
        let encodedSignature = try signatureEncoder.encode(HistoricalCacheSignature(
            version: 3, accounts: accounts, intervalHours: intervalHours,
            calendar: String(describing: calendar.identifier),
            timeZone: calendar.timeZone.identifier
        ))
        guard let signature = String(data: encodedSignature, encoding: .utf8) else { return nil }
        return try withDatabase { database in
            var revisions: [Int64] = []
            revisions.reserveCapacity(accounts.count)
            for configured in accounts {
                revisions.append(try accountRevision(configured.account, in: database))
            }
            let revisionKey = revisions.map(String.init).joined(separator: ",")
            let cached = try prepare("""
                SELECT payload FROM history_statistics_cache
                WHERE provider = ? AND signature = ? AND revisions = ?
                """, in: database)
            try bind(first.account.provider.rawValue, to: 1, in: cached, database: database)
            try bind(signature, to: 2, in: cached, database: database)
            try bind(revisionKey, to: 3, in: cached, database: database)
            let cachedStatus = sqlite3_step(cached)
            let cachedPayload = cachedStatus == SQLITE_ROW ? sqlite3_column_text(cached, 0).map { String(cString: $0) } : nil
            sqlite3_finalize(cached)
            if let cachedPayload, let data = cachedPayload.data(using: .utf8),
               let statistics = try? JSONDecoder().decode(HistoricalTrendStatistics.self, from: data) {
                return HistoricalStatisticsLoad(statistics: statistics, fromCache: true)
            }
            guard cachedStatus == SQLITE_ROW || cachedStatus == SQLITE_DONE else { throw error(database) }

            var weighted: [WeightedUsageTrend] = []
            weighted.reserveCapacity(accounts.count)
            for configured in accounts {
                let samples = try allSamples(account: configured.account, in: database)
                let series = UsageTrendCalculator.calculateHistory(
                    samples: samples, intervalHours: intervalHours,
                    endingAt: samples.last?.capturedAt ?? .distantPast
                )
                weighted.append(WeightedUsageTrend(series: series, capacity: configured.tier.capacityFactor))
            }
            let aggregate = UsageTrendAggregator.aggregate(weighted,
                                                           baselineCapacity: first.tier.capacityFactor)
            let empty = UsageTrendSeries(points: [], binHours: max(2, intervalHours), axisMaximum: 10,
                                         axisTicks: [0, 5, 10], sampleCount: 0)
            let statistics = HistoricalTrendStatistics.calculate(series: aggregate ?? empty, calendar: calendar)
            let payload = String(data: try JSONEncoder().encode(statistics), encoding: .utf8)!
            let save = try prepare("""
                INSERT INTO history_statistics_cache(provider, signature, revisions, payload)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(provider) DO UPDATE SET
                    signature = excluded.signature, revisions = excluded.revisions, payload = excluded.payload
                """, in: database)
            defer { sqlite3_finalize(save) }
            try bind(first.account.provider.rawValue, to: 1, in: save, database: database)
            try bind(signature, to: 2, in: save, database: database)
            try bind(revisionKey, to: 3, in: save, database: database)
            try bind(payload, to: 4, in: save, database: database)
            guard sqlite3_step(save) == SQLITE_DONE else { throw error(database) }
            return HistoricalStatisticsLoad(statistics: statistics, fromCache: false)
        }
    }

    private func accountRevision(_ account: AccountID, in database: OpaquePointer) throws -> Int64 {
        let statement = try prepare("""
            SELECT revision FROM history_account_revisions WHERE provider = ? AND directory = ?
            """, in: database)
        defer { sqlite3_finalize(statement) }
        try bind(account.provider.rawValue, to: 1, in: statement, database: database)
        try bind(account.directory, to: 2, in: statement, database: database)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error(database) }
        return status == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }

    private func allSamples(account: AccountID, in database: OpaquePointer) throws -> [UsageHistorySample] {
        let statement = try prepare("""
            SELECT captured_at, used_percent, resets_at, plan_tier FROM usage_samples
            WHERE provider = ? AND directory = ? ORDER BY captured_at ASC
            """, in: database)
        defer { sqlite3_finalize(statement) }
        try bind(account.provider.rawValue, to: 1, in: statement, database: database)
        try bind(account.directory, to: 2, in: statement, database: database)
        var samples: [UsageHistorySample] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return samples }
            guard status == SQLITE_ROW else { throw error(database) }
            samples.append(UsageHistorySample(
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                usedPercent: sqlite3_column_double(statement, 1),
                resetsAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                planTier: sqlite3_column_text(statement, 3).flatMap { UsagePlanTier(rawValue: String(cString: $0)) }
            ))
        }
    }

    func samples(account: AccountID, from start: Date, through end: Date) throws -> [UsageHistorySample] {
        try withDatabase { database in
            let sql = """
                SELECT captured_at, used_percent, resets_at, plan_tier
                FROM usage_samples
                WHERE provider = ? AND directory = ? AND captured_at >= ? AND captured_at <= ?
                ORDER BY captured_at ASC
                """
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            try bind(account.provider.rawValue, to: 1, in: statement, database: database)
            try bind(account.directory, to: 2, in: statement, database: database)
            sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, end.timeIntervalSince1970)
            var result: [UsageHistorySample] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw error(database) }
                let tier = sqlite3_column_text(statement, 3).flatMap {
                    UsagePlanTier(rawValue: String(cString: $0))
                }
                result.append(UsageHistorySample(
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    usedPercent: sqlite3_column_double(statement, 1),
                    resetsAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    planTier: tier
                ))
            }
        }
    }

    private func withDatabase<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { throw UsageHistoryError.database("Unable to create history database") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let database = pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open history database"
            if let pointer { sqlite3_close(pointer) }
            throw UsageHistoryError.database(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        let schema = """
            CREATE TABLE IF NOT EXISTS usage_samples (
                provider TEXT NOT NULL,
                directory TEXT NOT NULL,
                captured_at REAL NOT NULL,
                used_percent REAL NOT NULL,
                resets_at REAL,
                plan_tier TEXT,
                PRIMARY KEY (provider, directory, captured_at)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS history_account_revisions (
                provider TEXT NOT NULL, directory TEXT NOT NULL, revision INTEGER NOT NULL,
                PRIMARY KEY (provider, directory)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS history_statistics_cache (
                provider TEXT PRIMARY KEY, signature TEXT NOT NULL,
                revisions TEXT NOT NULL, payload TEXT NOT NULL
            ) WITHOUT ROWID;
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else { throw error(database) }
        let columns = try prepare("PRAGMA table_info(usage_samples)", in: database)
        var hasPlanTier = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1), String(cString: name) == "plan_tier" {
                hasPlanTier = true
            }
        }
        sqlite3_finalize(columns)
        if !hasPlanTier {
            guard sqlite3_exec(database, "ALTER TABLE usage_samples ADD COLUMN plan_tier TEXT", nil, nil, nil) == SQLITE_OK
            else { throw error(database) }
        }
        return try work(database)
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw error(database) }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer, database: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard status == SQLITE_OK else { throw error(database) }
    }

    private func error(_ database: OpaquePointer) -> UsageHistoryError {
        .database(String(cString: sqlite3_errmsg(database)))
    }
}
