import Foundation

struct TokenUsageSettings: Codable, Sendable, Equatable {
    var automatic = true
    var intervalMinutes = 30
    var excludedAccounts: [AccountID] = []
    func sources(in accounts: [AccountID]) -> [AccountID] { accounts.filter { !excludedAccounts.contains($0) } }
    var isValid: Bool { (1...1440).contains(intervalMinutes) }
}

enum TokenScanUpdate: Sendable {
    case started([AccountID])
    case completed(AccountID, succeeded: Bool)
    case saving
}

struct TokenScanProgress: Sendable {
    enum Phase: Sendable { case analyzing, saving, summarizing }
    var accounts: [AccountID]
    var completedAccounts: Int { completed.count }
    var completed: Set<AccountID> = []
    var failed: Set<AccountID> = []
    var startedAt: Date
    var phase: Phase = .analyzing
    var label: String { "账号 \(completedAccounts)/\(accounts.count)" }
    mutating func apply(_ update: TokenScanUpdate) {
        switch update {
        case .started: phase = .analyzing
        case .completed(let account, let succeeded):
            guard accounts.contains(account) else { return }
            completed.insert(account); if !succeeded { failed.insert(account) }
        case .saving: phase = .saving
        }
    }
}

struct TokenScanResult: Sendable {
    var events: [TokenUsageEvent] = []
    var warnings: [String] = []
    var lastSuccess: Date?
    var success: Bool { warnings.isEmpty }
}

/// Scheduling/persistence adapter only. All log discovery, parsing, replay,
/// deduplication, aggregation and pricing live in the unchanged ccusage source.
actor TokenLogScanner {
    private struct Cache: Codable {
        var schemaVersion = 6
        var engineVersion = "20.0.44"
        var timezone: String
        var accounts: [AccountID]
        var events: [TokenUsageEvent]
        var lastSuccess: Date?
        var warnings: [String]
    }
    private var cache: Cache?
    private var loaded = false
    private let cacheURL: URL
    private let engineURL: URL?
    init(cacheURL: URL = StorageSupport.appSupportURL("token-usage-cache.json"), engineURL: URL? = nil) {
        self.cacheURL = cacheURL; self.engineURL = engineURL
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        // The previous implementation's 289 MB event dump is not a summary.
        // Skip it without decoding; replace atomically after the first core scan.
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8_000_000,
           let data = try? Data(contentsOf: cacheURL),
           let stored = try? StorageSupport.decoder().decode(Cache.self, from: data),
           stored.schemaVersion == 6, stored.engineVersion == "20.0.44", stored.timezone == TimeZone.current.identifier { cache = stored }
    }
    func restore(accounts: [AccountID]) -> TokenScanResult {
        load()
        guard let cache else { return TokenScanResult() }
        let matching = Set(accounts).intersection(cache.accounts)
        return TokenScanResult(events: cache.events.filter { matching.contains($0.account) },
            warnings: Set(cache.accounts) == Set(accounts) ? cache.warnings : [],
            lastSuccess: Set(cache.accounts) == Set(accounts) ? cache.lastSuccess : nil)
    }
    func scan(accounts: [AccountID], now: Date? = nil, progress: @escaping @Sendable (TokenScanUpdate) -> Void = { _ in }) async throws -> TokenScanResult {
        load()
        var result = TokenScanResult()
        // Each configured root is an account. Reuse the unchanged ccusage core
        // for that root and retain its identity on every daily/model result.
        let selected = accounts.reduce(into: [AccountID]()) { if !$0.contains($1) { $0.append($1) } }
        progress(.started(selected))
        let executable = selected.isEmpty ? nil : try engineExecutable()
        let previous = cache?.events ?? []
        let timezone = TimeZone.current.identifier
        try await withThrowingTaskGroup(of: (AccountID, [TokenUsageEvent]?, String?).self) { group in
            var remaining = selected.makeIterator()
            func submit(_ account: AccountID) {
                group.addTask {
                    let outcome = await Task.detached(priority: .utility) { () -> (AccountID, [TokenUsageEvent]?, String?) in
                        do { return (account, try Self.analyze(account: account, executable: executable!, timezone: timezone), Optional<String>.none) }
                        catch { return (account, Optional<[TokenUsageEvent]>.none, Optional("\(account.directory)：\(error.localizedDescription)")) }
                    }.value
                    progress(.completed(account, succeeded: outcome.1 != nil))
                    return outcome
                }
            }
            // Bound process concurrency; ccusage parallelizes files itself.
            for _ in 0..<2 { if let account = remaining.next() { submit(account) } }
            while let (account, events, error) = try await group.next() {
                try Task.checkCancellation()
                if let events { result.events += events }
                else {
                    result.warnings.append(error ?? "日志来源读取失败")
                    result.events += previous.filter { $0.account == account }
                }
                if let account = remaining.next() { submit(account) }
            }
        }
        result.events.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        result.lastSuccess = result.success ? now ?? Date() : (Set(cache?.accounts ?? []) == Set(selected) ? cache?.lastSuccess : nil)
        progress(.saving)
        let stored = Cache(timezone: timezone, accounts: selected, events: result.events, lastSuccess: result.lastSuccess, warnings: result.warnings)
        try StorageSupport.write(stored, to: cacheURL)
        cache = stored
        return result
    }
    private nonisolated static func analyze(account: AccountID, executable: URL, timezone: String) throws -> [TokenUsageEvent] {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: account.directory) else { throw CocoaError(.fileReadNoPermission) }
        if account.provider == .claude && !fm.fileExists(atPath: URL(fileURLWithPath: account.directory).appendingPathComponent("projects").path) { return [] }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = [account.provider.rawValue, timezone]
        var environment = ProcessInfo.processInfo.environment
        environment[account.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = account.directory
        process.environment = environment
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return try decodeReport(data, provider: account.provider, account: account)
    }
    private func engineExecutable() throws -> URL {
        if let engineURL { return engineURL }
        if let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("capbar-usage-engine"), FileManager.default.isExecutableFile(atPath: path.path) { return path }
        if let path = CapBarResources.url(forResource: "capbar-usage-engine", withExtension: ""), FileManager.default.isExecutableFile(atPath: path.path) { return path }
        throw CocoaError(.executableNotLoadable)
    }
    private struct Report: Decodable { var version: String; var rows: [Row] }
    private struct Row: Decodable {
        var date: String, model: String
        var input: Int64, output: Int64, cacheWrite: Int64, cacheRead: Int64, total: Int64
        var cost: Double
        var missingPricing: Bool
    }
    static func decodeReport(_ data: Data, provider: Provider, account: AccountID, calendar: Calendar = .current) throws -> [TokenUsageEvent] {
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.version == "20.0.44" else { throw CocoaError(.coderReadCorrupt) }
        var protocolCalendar = Calendar(identifier: .gregorian); protocolCalendar.timeZone = calendar.timeZone
        let formatter = DateFormatter(); formatter.calendar = protocolCalendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return try report.rows.map { row in
            guard let date = formatter.date(from: row.date), min(row.input, row.output, row.cacheRead, row.cacheWrite, row.total) >= 0, row.cost.isFinite, row.cost >= 0 else { throw CocoaError(.coderReadCorrupt) }
            return TokenUsageEvent(id: "\(provider.rawValue):\(account.directory):\(row.date):\(row.model)", account: account,
                timestamp: date, model: row.model,
                tokens: TokenCounts(input: row.input, output: row.output, cacheWrite: row.cacheWrite, cacheRead: row.cacheRead, reportedTotal: row.total),
                apiCost: row.cost, missingPricing: row.missingPricing)
        }
    }
}
