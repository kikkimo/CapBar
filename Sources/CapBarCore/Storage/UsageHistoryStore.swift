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

actor UsageHistoryStore {
    private let url: URL

    init(url: URL = StorageSupport.appSupportURL("usage-history.sqlite3")) {
        self.url = url
    }

    func append(account: AccountID, snapshot: UsageSnapshot, planTier: UsagePlanTier? = nil) throws -> Bool {
        guard let weekly = snapshot.windows.first(where: { $0.kind == .sevenDay }) else { return false }
        try withDatabase { database in
            let sql = """
                INSERT INTO usage_samples(provider, directory, captured_at, used_percent, resets_at, plan_tier)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, directory, captured_at) DO UPDATE SET
                    used_percent = excluded.used_percent,
                    resets_at = excluded.resets_at,
                    plan_tier = COALESCE(excluded.plan_tier, usage_samples.plan_tier)
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
        }
        return true
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
