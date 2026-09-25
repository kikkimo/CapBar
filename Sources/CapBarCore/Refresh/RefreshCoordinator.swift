import Foundation

protocol UsageProvider: Sendable {
    func probe(account: AccountID) async throws -> UsageSnapshot
}

struct CoordinatorViewState: Sendable {
    let records: [AccountID: AccountRecord]
    let refreshing: Set<AccountID>
}

actor RefreshCoordinator {
    private let settingsStore: SettingsStore
    private let snapshotStore: SnapshotStore
    private let providers: [Provider: any UsageProvider]
    private let runner: RetryRunner
    private let now: @Sendable () -> Date
    private var records: [AccountID: AccountRecord]
    private var refreshing: Set<AccountID> = []
    private var activeTasks: [AccountID: Task<Void, Never>] = [:]
    private var shuttingDown = false

    init(
        settingsStore: SettingsStore,
        snapshotStore: SnapshotStore,
        providers: [Provider: any UsageProvider],
        policy: ProbePolicy,
        now: @escaping @Sendable () -> Date = Date.init,
        pause: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        chooseDelay: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) async throws {
        try policy.validate()
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore
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

    func requestRefresh(_ id: AccountID) async -> Bool {
        guard !shuttingDown, !refreshing.contains(id), let provider = providers[id.provider] else { return false }
        refreshing.insert(id)
        let previous = records[id]
        var record = previous ?? AccountRecord(id: id, snapshot: nil, lastAttemptAt: nil, lastError: nil)
        record.lastAttemptAt = now()
        record.lastError = nil
        records[id] = record
        do {
            try await snapshotStore.update(record)
        } catch {
            records[id] = previous
            refreshing.remove(id)
            return false
        }
        if shuttingDown {
            refreshing.remove(id)
            return false
        }

        activeTasks[id] = Task {
            await self.perform(id, provider: provider)
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
            if await requestRefresh(account) { started += 1 }
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
            if await requestRefresh(account) { started += 1 }
        }
        return started
    }

    private func perform(_ id: AccountID, provider: any UsageProvider) async {
        var record = records[id] ?? AccountRecord(id: id, snapshot: nil, lastAttemptAt: now(), lastError: nil)
        do {
            let result = try await runner.run { try await provider.probe(account: id) }
            record.snapshot = result
            record.lastError = nil
        } catch ProbeFailure.permanent {
            record.lastError = "账号不可用，请检查登录或目录"
        } catch {
            record.lastError = "探测失败，请手动重试"
        }

        do {
            try await snapshotStore.update(record)
        } catch {
            record.lastError = "无法保存探测结果"
        }
        records[id] = record
        refreshing.remove(id)
        activeTasks.removeValue(forKey: id)
    }
}
