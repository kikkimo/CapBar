import Foundation
@testable import CapBarCore

private final class SamplingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private actor SamplingProvider: UsageProvider {
    private let clock: SamplingTestClock
    private let resetAt: Date?
    private(set) var calls = 0
    init(clock: SamplingTestClock, resetAt: Date? = nil) {
        self.clock = clock
        self.resetAt = resetAt
    }
    func probe(account: AccountID) async throws -> UsageSnapshot {
        calls += 1
        let weekly = try QuotaWindow(kind: .sevenDay, remainingPercent: 80, resetsAt: resetAt)
        return UsageSnapshot(
            identity: AccountIdentity(email: "sample@example.com", plan: nil, organization: nil),
            windows: [weekly], capturedAt: clock.now()
        )
    }
}

@MainActor func runUsageSamplingChecks() async {
    let hour: TimeInterval = 3_600
    func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: hours * hour) }
    let schedule = UsageSamplingSchedule.self

    check(schedule.nextRegular(after: at(2.5), intervalHours: 3) == at(3), "three-hour cadence uses UTC zero, three and six")
    check(schedule.nextRegular(after: at(3), intervalHours: 3) == at(6), "boundary is not sampled twice")
    check(schedule.nextRegular(after: at(23), intervalHours: 8) == at(24), "eight-hour cadence rolls across UTC midnight")
    check(schedule.nextEvent(after: at(0), intervalHours: 4, resetAt: at(7)) == at(3), "four-hour mode enters hourly window four hours before reset")
    check(schedule.nextEvent(after: at(3), intervalHours: 4, resetAt: at(7)) == at(4), "hourly reset window advances by one hour")
    check(schedule.nextEvent(after: at(0), intervalHours: 6, resetAt: at(7)) == at(1), "six-hour mode enters hourly window six hours before reset")
    check(schedule.nextEvent(after: at(0), intervalHours: 8, resetAt: at(7)) == at(1), "eight-hour mode does not skip its reset window")
    check(schedule.nextEvent(after: at(6), intervalHours: 4, resetAt: at(7)) == at(7 + 5.0 / 60), "reset probe occurs five minutes after reset")
    check(schedule.nextEvent(after: at(7 + 5.0 / 60), intervalHours: 4, resetAt: at(7)) == at(8), "normal UTC cadence resumes after reset")
    check(schedule.nextEvent(after: at(6), intervalHours: 1, resetAt: at(7)) == at(7 + 5.0 / 60), "one-hour regular probe at exact reset is replaced by five-minute probe")
    check(schedule.previousEvent(atOrBefore: at(5.5), intervalHours: 4, resetAt: at(7)) == at(5), "restart can identify a missed hourly reset-window point")
    check(schedule.nextEvent(after: at(2), intervalHours: 3, resetAt: nil) == at(3), "unknown reset uses only normal UTC cadence")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let account = AccountID(provider: .claude, directory: folder.appendingPathComponent("claude-demo").path)
    let clock = SamplingTestClock(at(2.5))
    let provider = SamplingProvider(clock: clock)
    let settingsStore = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    let snapshotStore = SnapshotStore(url: folder.appendingPathComponent("snapshots.json"))
    do {
        let coordinator = try await RefreshCoordinator(
            settingsStore: settingsStore, snapshotStore: snapshotStore,
            providers: [.claude: provider], policy: ProbePolicy.bundled(), now: { clock.now() }
        )
        let sampler = UsageSamplingController(coordinator: coordinator, now: { clock.now() })
        var settings = UserSettings(accounts: [account], defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5, samplingIntervalHours: 3)
        await sampler.start(settings: settings)
        check(await sampler.tick() == 0, "disabled statistics do not sample")
        settings.usageStatisticsEnabled = true
        settings.samplingScheduleStartedAt = clock.now()
        await sampler.update(settings: settings)
        check(await sampler.nextDue(for: account) == at(3), "enabling at 02:30 waits for 03:00 UTC")
        clock.set(at(2.9))
        check(await sampler.tick() == 0, "no probe before first UTC slot")
        clock.set(at(3))
        check(await sampler.tick() == 1, "first UTC slot launches one probe")
        for _ in 0..<100 {
            if await !coordinator.isRefreshing(account) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(await provider.calls == 1, "first scheduled probe uses existing coordinator")

        clock.set(at(15))
        check(await sampler.tick() == 1, "waking after several missed slots starts one catch-up probe")
        check(await sampler.nextDue(for: account) == at(18), "catch-up returns to fixed UTC timetable")
        for _ in 0..<100 {
            if await !coordinator.isRefreshing(account) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(await provider.calls == 2, "missed slots are not replayed individually")

        settings.usageStatisticsEnabled = false
        settings.samplingScheduleStartedAt = nil
        await sampler.update(settings: settings)
        clock.set(at(18))
        check(await sampler.tick() == 0, "turning off statistics stops background probes")

        settings.usageStatisticsEnabled = true
        settings.samplingScheduleStartedAt = at(2.5)
        clock.set(at(22))
        let restarted = UsageSamplingController(coordinator: coordinator, now: { clock.now() })
        await restarted.start(settings: settings)
        check(await restarted.nextDue(for: account) == at(22), "restart after missed UTC slots is due once immediately")
        check(await restarted.tick() == 1, "restart runs one catch-up probe")
        for _ in 0..<100 {
            if await !coordinator.isRefreshing(account) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(await provider.calls == 3, "restart does not replay every missed sample")
    } catch {
        check(false, "sampling controller setup should succeed: \(error)")
    }

    do {
        let resetFolder = folder.appendingPathComponent("reset-discovery", isDirectory: true)
        let resetAccount = AccountID(provider: .claude, directory: resetFolder.appendingPathComponent("claude-demo").path)
        let discoveryClock = SamplingTestClock(at(0))
        let discoveryProvider = SamplingProvider(clock: discoveryClock, resetAt: at(7))
        let discoveryCoordinator = try await RefreshCoordinator(
            settingsStore: SettingsStore(url: resetFolder.appendingPathComponent("settings.json")),
            snapshotStore: SnapshotStore(url: resetFolder.appendingPathComponent("snapshots.json")),
            providers: [.claude: discoveryProvider], policy: ProbePolicy.bundled(), now: { discoveryClock.now() }
        )
        let sampler = UsageSamplingController(coordinator: discoveryCoordinator, now: { discoveryClock.now() })
        let settings = UserSettings(
            accounts: [resetAccount], defaultsSeeded: true, autoRefreshOnOpen: false,
            refreshThresholdMinutes: 5, usageStatisticsEnabled: true,
            samplingIntervalHours: 4, samplingScheduleStartedAt: at(0)
        )
        await sampler.start(settings: settings)
        check(await sampler.nextDue(for: resetAccount) == at(4), "unknown reset starts on regular UTC cadence")
        discoveryClock.set(at(4))
        check(await sampler.tick() == 1, "regular probe discovers reset time")
        for _ in 0..<100 {
            if await !discoveryCoordinator.isRefreshing(resetAccount) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        discoveryClock.set(at(5))
        check(await sampler.tick() == 1, "newly discovered reset activates hourly sampling without waiting for next regular slot")
        await discoveryCoordinator.cancelAll()
    } catch {
        check(false, "reset-discovery setup should succeed: \(error)")
    }
}
