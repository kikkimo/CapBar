import Foundation

actor UsageSamplingController {
    private let coordinator: RefreshCoordinator
    private let now: @Sendable () -> Date
    private var settings: UserSettings?
    private var dueAt: [AccountID: Date] = [:]
    private var knownResetAt: [AccountID: Date] = [:]

    init(coordinator: RefreshCoordinator, now: @escaping @Sendable () -> Date = Date.init) {
        self.coordinator = coordinator
        self.now = now
    }

    func start(settings: UserSettings) async {
        self.settings = settings
        dueAt.removeAll()
        knownResetAt.removeAll()
        guard settings.usageStatisticsEnabled else { return }
        let records = await coordinator.viewState().records
        let current = now()
        for account in settings.accounts {
            let reset = weeklyReset(in: records[account])
            knownResetAt[account] = reset
            let lastAttempt = records[account]?.lastAttemptAt
            if let activation = settings.samplingScheduleStartedAt,
               lastAttempt.map({ $0 < activation }) ?? true {
                let first = UsageSamplingSchedule.nextRegular(after: activation, intervalHours: settings.samplingIntervalHours)
                dueAt[account] = first <= current ? current : first
            } else if let lastAttempt {
                let latestSlot = UsageSamplingSchedule.previousEvent(
                    atOrBefore: current, intervalHours: settings.samplingIntervalHours, resetAt: reset
                )
                dueAt[account] = latestSlot > lastAttempt
                    ? current
                    : UsageSamplingSchedule.nextEvent(after: current, intervalHours: settings.samplingIntervalHours, resetAt: reset)
            } else {
                dueAt[account] = UsageSamplingSchedule.nextRegular(after: current, intervalHours: settings.samplingIntervalHours)
            }
        }
    }

    func update(settings newSettings: UserSettings) {
        let previous = settings
        settings = newSettings
        guard newSettings.usageStatisticsEnabled else {
            dueAt.removeAll()
            knownResetAt.removeAll()
            return
        }
        let current = now()
        if previous?.usageStatisticsEnabled != true
            || previous?.samplingIntervalHours != newSettings.samplingIntervalHours
            || previous?.samplingScheduleStartedAt != newSettings.samplingScheduleStartedAt {
            dueAt = Dictionary(uniqueKeysWithValues: newSettings.accounts.map { account in
                (account, UsageSamplingSchedule.nextRegular(after: current, intervalHours: newSettings.samplingIntervalHours))
            })
            return
        }
        let configured = Set(newSettings.accounts)
        dueAt = dueAt.filter { configured.contains($0.key) }
        knownResetAt = knownResetAt.filter { configured.contains($0.key) }
        for account in configured where dueAt[account] == nil {
            dueAt[account] = UsageSamplingSchedule.nextRegular(after: current, intervalHours: newSettings.samplingIntervalHours)
        }
    }

    func tick() async -> Int {
        guard let settings, settings.usageStatisticsEnabled else { return 0 }
        let current = now()
        let records = await coordinator.viewState().records
        var started = 0
        for account in settings.accounts {
            let reset = weeklyReset(in: records[account])
            if let reset, knownResetAt[account] != reset {
                knownResetAt[account] = reset
                if let lastAttempt = records[account]?.lastAttemptAt {
                    let special = UsageSamplingSchedule.nextEvent(
                        after: lastAttempt, intervalHours: settings.samplingIntervalHours, resetAt: reset
                    )
                    if let existing = dueAt[account] { dueAt[account] = min(existing, special) }
                }
            } else if reset == nil {
                knownResetAt.removeValue(forKey: account)
            }
            guard let due = dueAt[account], due <= current else { continue }
            dueAt[account] = UsageSamplingSchedule.nextEvent(
                after: current, intervalHours: settings.samplingIntervalHours,
                resetAt: reset
            )
            if await coordinator.requestRefresh(account, recordHistory: true) { started += 1 }
        }
        return started
    }

    func nextDue(for account: AccountID) -> Date? { dueAt[account] }

    func stop() { dueAt.removeAll(); knownResetAt.removeAll(); settings = nil }

    private func weeklyReset(in record: AccountRecord?) -> Date? {
        record?.snapshot?.windows.first(where: { $0.kind == .sevenDay })?.resetsAt
    }
}
