import Foundation

protocol UsageProvider: Sendable {
    func probe(account: AccountID) async throws -> UsageSnapshot
}

struct CoordinatorViewState: Sendable {
    let records: [AccountID: AccountRecord]
    let refreshing: Set<AccountID>
}

struct RefreshExecution: Sendable {
    let id: UUID
    let account: AccountID
    let startedAt: Date
    var state = "running"
    var attempt = 0
    var finishedAt: Date?
    var record: AccountRecord?
    var historyWrite = "not_requested"
    var isFinished: Bool { finishedAt != nil }
}

actor RefreshCoordinator {
    private let settingsStore: SettingsStore
    private let snapshotStore: SnapshotStore
    private let historyStore: UsageHistoryStore?
    private let providers: [Provider: any UsageProvider]
    private let runner: RetryRunner
    private let now: @Sendable () -> Date
    private var records: [AccountID: AccountRecord]
    private var refreshing: Set<AccountID> = []
    private var activeTasks: [AccountID: Task<Void, Never>] = [:]
    private var shuttingDown = false
    private var executionIDs: [AccountID: UUID] = [:]
    private var executions: [UUID: RefreshExecution] = [:]

    func activeExecutions() -> [AccountID: RefreshExecution] { executionIDs.compactMapValues { executions[$0] } }

    func activeExecution(_ account: AccountID) -> RefreshExecution? {
        executionIDs[account].flatMap { executions[$0] }
    }
    func latestExecution(_ account: AccountID, since date: Date) -> RefreshExecution? {
        executions.values.filter { $0.account == account && $0.startedAt >= date }.max { $0.startedAt < $1.startedAt }
    }
    func execution(_ id: UUID) -> RefreshExecution? { executions[id] }

    // Actor-atomic enrollment: UI, scheduled and external refreshes share this path.
    func joinOrRefresh(_ account: AccountID, recordHistory: Bool, planTierOverride: UsagePlanTier?) async -> (UUID, Bool)? {
        if let existing = executionIDs[account] { return (existing, false) }
        let id = UUID()
        guard await beginRefresh(account, executionID: id, recordHistory: recordHistory, planTierOverride: planTierOverride) else { return nil }
        return (id, true)
    }

    init(
        settingsStore: SettingsStore,
        snapshotStore: SnapshotStore,
        historyStore: UsageHistoryStore? = nil,
        providers: [Provider: any UsageProvider],
        policy: ProbePolicy,
        now: @escaping @Sendable () -> Date = Date.init,
        pause: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        chooseDelay: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) async throws {
        try policy.validate()
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore
        self.historyStore = historyStore
        self.providers = providers
        self.runner = RetryRunner(policy: policy, pause: pause, chooseDelay: chooseDelay)
        self.now = now
        self.records = try await snapshotStore.load()
    }

    func state() -> [AccountID: AccountRecord] { records }

    func viewState() -> CoordinatorViewState {
        CoordinatorViewState(records: records, refreshing: refreshing)
    }

    func isRefreshing(_ id: AccountID) -> Bool { refreshing.contains(id) }

    func requestRefresh(_ id: AccountID, recordHistory: Bool = false, planTierOverride: UsagePlanTier? = nil) async -> Bool {
        await beginRefresh(id, executionID: UUID(), recordHistory: recordHistory, planTierOverride: planTierOverride)
    }

    private func beginRefresh(_ id: AccountID, executionID: UUID, recordHistory: Bool, planTierOverride: UsagePlanTier?) async -> Bool {
        guard !shuttingDown, !refreshing.contains(id), let provider = providers[id.provider] else { return false }
        refreshing.insert(id)
        executionIDs[id] = executionID
        executions[executionID] = RefreshExecution(id: executionID, account: id, startedAt: now(), historyWrite: recordHistory ? "pending" : "not_requested")
        let completed = executions.values.filter(\.isFinished).sorted { $0.startedAt < $1.startedAt }
        for old in completed.prefix(max(0, executions.count - 1000)) { executions.removeValue(forKey: old.id) }
        let previous = records[id]
        var record = previous ?? AccountRecord(id: id, snapshot: nil, lastAttemptAt: nil, lastError: nil)
        record.lastAttemptAt = now()
        record.lastError = nil
        records[id] = record
        do {
            try await snapshotStore.update(record)
        } catch {
            records[id] = previous
            finishExecution(id, state: "failed", record: previous)
            return false
        }
        if shuttingDown {
            finishExecution(id, state: "interrupted", record: previous)
            return false
        }

        activeTasks[id] = Task {
            await self.perform(id, provider: provider, recordHistory: recordHistory, planTierOverride: planTierOverride)
        }
        return true
    }

    func cancelAll() async {
        shuttingDown = true
        let running = Array(activeTasks.values)
        running.forEach { $0.cancel() }
        for task in running { await task.value }
    }

    func requestRefreshAll() async -> Int {
        guard let settings = try? await settingsStore.loadOrSeed() else { return 0 }
        return await requestRefreshAll(settings: settings)
    }

    func requestRefreshAll(settings: UserSettings) async -> Int {
        var started = 0
        for account in settings.accounts {
            let override = settings.planOverrides.first { $0.account == account }?.tier
            if await requestRefresh(account, recordHistory: settings.usageStatisticsEnabled, planTierOverride: override) { started += 1 }
        }
        return started
    }

    func openedPopover(settings: UserSettings) async -> Int {
        guard settings.autoRefreshOnOpen else { return 0 }
        var started = 0
        for account in settings.accounts {
            guard !refreshing.contains(account) else { continue }
            if let last = records[account]?.lastAttemptAt,
               now().timeIntervalSince(last) < Double(settings.refreshThresholdMinutes * 60) {
                continue
            }
            let override = settings.planOverrides.first { $0.account == account }?.tier
            if await requestRefresh(account, recordHistory: settings.usageStatisticsEnabled, planTierOverride: override) { started += 1 }
        }
        return started
    }

    private func perform(_ id: AccountID, provider: any UsageProvider, recordHistory: Bool,
                         planTierOverride: UsagePlanTier?) async {
        var record = records[id] ?? AccountRecord(id: id, snapshot: nil, lastAttemptAt: now(), lastError: nil)
        let previousSnapshot = record.snapshot
        var successfulSnapshot: UsageSnapshot?
        do {
            let result = try await runner.run(progress: { attempt, waiting in
                await self.setProgress(id, attempt: attempt, waiting: waiting)
            }) { try await provider.probe(account: id) }
            record.snapshot = result
            record.lastError = nil
            successfulSnapshot = result
        } catch is CancellationError {
            record.lastError = "探测已中断"
        } catch ProbeFailure.permanent {
            record.lastError = "账号不可用，请检查登录或目录"
        } catch {
            record.lastError = "探测失败，请手动重试"
        }

        do {
            try await snapshotStore.update(record)
        } catch {
            record.snapshot = previousSnapshot
            record.lastError = "无法保存探测结果"
            successfulSnapshot = nil
        }
        if recordHistory, let successfulSnapshot {
            do {
                guard let historyStore else { throw UsageHistoryError.database("History store unavailable") }
                let storedOverride = (try? await settingsStore.loadOrSeed())?.planOverrides
                    .first(where: { $0.account == id })?.tier
                let override = planTierOverride ?? storedOverride
                let tier = override?.provider == id.provider ? override
                    : UsagePlanTier.detect(provider: id.provider, rawPlan: successfulSnapshot.identity.plan)
                _ = try await historyStore.append(account: id, snapshot: successfulSnapshot, planTier: tier)
                if let executionID = executionIDs[id] { executions[executionID]?.historyWrite = "stored" }
            } catch {
                if let executionID = executionIDs[id] { executions[executionID]?.historyWrite = "failed" }
                record.lastError = "历史记录未能保存"
                try? await snapshotStore.update(record)
            }
        }
        records[id] = record
        finishExecution(id, state: Task.isCancelled ? "interrupted" : successfulSnapshot == nil ? "failed" : "succeeded", record: record)
    }

    private func setProgress(_ account: AccountID, attempt: Int, waiting: Bool) {
        guard let id = executionIDs[account] else { return }
        executions[id]?.attempt = attempt
        executions[id]?.state = waiting ? "retry_wait" : "running"
    }

    private func finishExecution(_ account: AccountID, state: String, record: AccountRecord?) {
        if let id = executionIDs.removeValue(forKey: account) {
            executions[id]?.state = state
            executions[id]?.finishedAt = now()
            executions[id]?.record = record
            if executions[id]?.historyWrite == "pending" { executions[id]?.historyWrite = "not_requested" }
        }
        refreshing.remove(account)
        activeTasks.removeValue(forKey: account)
    }
}
