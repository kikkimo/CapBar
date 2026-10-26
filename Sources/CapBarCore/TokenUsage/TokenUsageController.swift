import Combine
import Foundation

@MainActor final class TokenUsageController: ObservableObject {
    @Published private(set) var events: [TokenUsageEvent] = []
    @Published private(set) var summary = TokenUsageSummary()
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: TokenScanProgress?
    @Published private(set) var isSummarizing = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var nextScan: Date?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var period: TokenPeriod = .sevenDays
    @Published private(set) var provider: Provider?
    @Published private(set) var account: AccountID?
    @Published private(set) var range: TokenDateRange
    @Published private(set) var settings: TokenUsageSettings
    @Published private(set) var accounts: [AccountID]
    private let scanner: TokenLogScanner
    private let operation: (@Sendable ([AccountID], Date) async throws -> TokenScanResult)?
    private var generation = 0
    private var started = false
    private var lastAttempt: Date?
    private var retryAfterConfiguration = false
    private var calendar: Calendar
    private var summaryTask: Task<Void, Never>?

    init(scanner: TokenLogScanner = TokenLogScanner(), settings: TokenUsageSettings = TokenUsageSettings(), accounts: [AccountID] = [],
         calendar: Calendar = .current,
         operation: (@Sendable ([AccountID], Date) async throws -> TokenScanResult)? = nil) {
        self.scanner = scanner; self.settings = settings; self.accounts = accounts; self.calendar = calendar
        self.range = .preset(.sevenDays, now: Date(), calendar: calendar)
        self.operation = operation
    }
    var sources: [AccountID] { settings.sources(in: accounts) }
    func start(now: Date = Date()) async {
        guard !started else { return }; started = true
        let revision = generation
        let stored = await scanner.restore(accounts: sources)
        guard revision == generation else { return }
        events = stored.events; lastSuccess = stored.lastSuccess; warnings = stored.warnings
        nextScan = settings.automatic && !sources.isEmpty ? (lastSuccess?.addingTimeInterval(Double(settings.intervalMinutes) * 60) ?? now) : nil
        refreshSummary()
        await summaryTask?.value
        await tick(now: now)
    }
    func configure(settings newSettings: TokenUsageSettings, accounts newAccounts: [AccountID], now: Date = Date()) {
        guard newSettings.isValid else { return }
        let selectionChanged = Set(sources) != Set(newSettings.sources(in: newAccounts))
        let intervalChanged = settings.intervalMinutes != newSettings.intervalMinutes
        let autoChanged = settings.automatic != newSettings.automatic
        guard selectionChanged || intervalChanged || autoChanged || accounts != newAccounts else { return }
        if selectionChanged { generation += 1 }
        settings = newSettings; accounts = newAccounts
        if let account, !sources.contains(account) { self.account = nil }
        if !settings.automatic || sources.isEmpty { retryAfterConfiguration = false }
        if selectionChanged {
            events = events.filter { sources.contains($0.account) }; lastSuccess = nil; warnings = []
            refreshSummary()
        }
        nextScan = newSettings.automatic && !sources.isEmpty ? (selectionChanged || autoChanged ? now : (lastAttempt ?? lastSuccess ?? now).addingTimeInterval(Double(settings.intervalMinutes) * 60)) : nil
        if isScanning && selectionChanged { retryAfterConfiguration = started && settings.automatic }
        else if started && settings.automatic && selectionChanged { Task { await scan(now: now) } }
    }
    func tick(now: Date = Date()) async {
        if period != .custom {
            let newRange = TokenDateRange.preset(period, now: now, calendar: calendar)
            if range != newRange { range = newRange; refreshSummary() }
        }
        guard settings.automatic, !sources.isEmpty, let nextScan, now >= nextScan else { return }
        await scan(now: now)
    }
    func scan(now: Date = Date()) async {
        guard !isScanning, !sources.isEmpty else { return }
        isScanning = true; let revision = generation, selected = sources
        scanProgress = TokenScanProgress(accounts: selected, startedAt: Date())
        lastAttempt = now
        nextScan = settings.automatic ? now.addingTimeInterval(Double(settings.intervalMinutes) * 60) : nil
        do {
            let result: TokenScanResult
            if let operation { result = try await operation(selected, now) }
            else {
                result = try await scanner.scan(accounts: selected, progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.isScanning, self.generation == revision else { return }
                        self.scanProgress?.apply(update)
                    }
                })
            }
            if revision == generation {
                events = result.events; warnings = result.warnings
                lastSuccess = result.lastSuccess
                scanProgress?.phase = .summarizing
                refreshSummary()
                await summaryTask?.value
            }
        } catch {
            if revision == generation { warnings = ["扫描未完成，保留上次结果：\(error.localizedDescription)"] }
        }
        isScanning = false; scanProgress = nil
        if retryAfterConfiguration { retryAfterConfiguration = false; await scan() }
    }
    func select(period: TokenPeriod, now: Date = Date()) {
        guard period != .custom else { return }
        self.period = period; range = .preset(period, now: now, calendar: calendar); refreshSummary()
    }
    @discardableResult func selectCustom(start: Date, end: Date, now: Date = Date()) -> Bool {
        guard calendar.startOfDay(for: end) <= calendar.startOfDay(for: now), let range = TokenDateRange.custom(start: start, end: end, calendar: calendar) else { return false }
        period = .custom; self.range = range; refreshSummary(); return true
    }
    func select(provider: Provider?) {
        self.provider = provider
        if let account, let provider, account.provider != provider { self.account = nil }
        refreshSummary()
    }
    func select(account: AccountID?) {
        guard account == nil || sources.contains(account!) else { return }
        self.account = account
        if let account { provider = account.provider }
        refreshSummary()
    }
    func waitForSummary() async { await summaryTask?.value }
    private func refreshSummary() {
        summaryTask?.cancel()
        summary = TokenUsageSummary(); isSummarizing = true
        let events = self.events, sources = self.sources, range = self.range, provider = self.provider, calendar = self.calendar, account = self.account
        let work = Task.detached(priority: .utility) {
            TokenUsageSummary.build(events: events.filter { sources.contains($0.account) }, range: range, provider: provider, calendar: calendar, account: account)
        }
        summaryTask = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, let self else { return }
            self.summary = result; self.isSummarizing = false
        }
    }
}
