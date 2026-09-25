import Foundation
@testable import CapBarCore

private actor HoldingProvider: UsageProvider {
    private var continuations: [AccountID: CheckedContinuation<UsageSnapshot, any Error>] = [:]
    private var calls: [AccountID: Int] = [:]

    func probe(account: AccountID) async throws -> UsageSnapshot {
        calls[account, default: 0] += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[account] = continuation
        }
    }

    func callCount(_ account: AccountID) -> Int { calls[account, default: 0] }
    func finish(_ account: AccountID, snapshot: UsageSnapshot) {
        continuations.removeValue(forKey: account)?.resume(returning: snapshot)
    }
}

private actor FailingProvider: UsageProvider {
    private(set) var calls = 0
    func probe(account: AccountID) async throws -> UsageSnapshot {
        calls += 1
        throw ProbeFailure.permanent("invalid credentials")
    }
}

@MainActor func runRefreshCoordinatorChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let settingsStore = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    let snapshotStore = SnapshotStore(url: folder.appendingPathComponent("snapshots.json"))
    let a = AccountID(provider: .claude, directory: "~/.claude-a")
    let b = AccountID(provider: .claude, directory: "~/.claude-b")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = UsageSnapshot(identity: AccountIdentity(email: "a@example.com", plan: "Team", organization: nil), windows: [], capturedAt: now.addingTimeInterval(-600))
    let provider = HoldingProvider()
    let settings = UserSettings(accounts: [a, b], defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5)
    do {
        try await settingsStore.save(settings)
        try await snapshotStore.update(AccountRecord(id: a, snapshot: old, lastAttemptAt: now.addingTimeInterval(-180), lastError: nil))
        try await snapshotStore.update(AccountRecord(id: b, snapshot: old, lastAttemptAt: now.addingTimeInterval(-360), lastError: nil))
        let coordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [.claude: provider], policy: ProbePolicy.bundled(), now: { now }, pause: { _ in })
        check(await coordinator.openedPopover(settings: settings) == 0, "open with auto refresh off starts no sessions")
        check(await coordinator.requestRefresh(a), "manual single refresh bypasses threshold")
        check(!(await coordinator.requestRefresh(a)), "busy account rejects another single refresh")
        check(await coordinator.isRefreshing(a), "busy state appears immediately")
        check(await coordinator.requestRefreshAll() == 1, "all refresh skips busy account and starts idle account")
        check(await coordinator.requestRefreshAll() == 0, "repeated all refresh queues nothing while both busy")
        let loading = await coordinator.state()
        check(loading[a]?.snapshot?.capturedAt == old.capturedAt, "loading retains prior snapshot time")
        check(loading[a]?.lastAttemptAt == now, "attempt time is recorded at start")

        for _ in 0..<100 {
            let aCount = await provider.callCount(a)
            let bCount = await provider.callCount(b)
            if aCount > 0 && bCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await provider.finish(a, snapshot: UsageSnapshot(identity: old.identity, windows: [], capturedAt: now))
        await provider.finish(b, snapshot: UsageSnapshot(identity: old.identity, windows: [], capturedAt: now))
        for _ in 0..<100 {
            let aBusy = await coordinator.isRefreshing(a)
            let bBusy = await coordinator.isRefreshing(b)
            if !aBusy && !bBusy { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(!(await coordinator.isRefreshing(a)), "completion clears loading state")
        check((await coordinator.state())[a]?.snapshot?.capturedAt == now, "completion replaces account snapshot")

        var autoSettings = settings
        autoSettings.autoRefreshOnOpen = true
        let cooldown = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [.claude: provider], policy: ProbePolicy.bundled(), now: { now.addingTimeInterval(60) }, pause: { _ in })
        check(await cooldown.openedPopover(settings: autoSettings) == 0, "recent per-account attempts remain on cooldown")

        try await snapshotStore.update(AccountRecord(id: a, snapshot: old, lastAttemptAt: now.addingTimeInterval(-180), lastError: nil))
        try await snapshotStore.update(AccountRecord(id: b, snapshot: old, lastAttemptAt: now.addingTimeInterval(-360), lastError: nil))
        let dueProvider = HoldingProvider()
        let due = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [.claude: dueProvider], policy: ProbePolicy.bundled(), now: { now }, pause: { _ in })
        check(await due.openedPopover(settings: autoSettings) == 1, "auto-open refreshes only the overdue account")
        let aLoading = await due.isRefreshing(a)
        let bLoading = await due.isRefreshing(b)
        check(!aLoading && bLoading, "fresh account stays idle while stale account loads")
        for _ in 0..<100 {
            if await dueProvider.callCount(b) > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await dueProvider.finish(b, snapshot: UsageSnapshot(identity: old.identity, windows: [], capturedAt: now))

        let failingProvider = FailingProvider()
        let failed = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [.claude: failingProvider], policy: ProbePolicy.bundled(), now: { now }, pause: { _ in })
        check(await failed.requestRefresh(a), "manual refresh starts after previous failed or old attempt")
        for _ in 0..<100 {
            if await !failed.isRefreshing(a) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let failedRecord = (await failed.state())[a]
        check(failedRecord?.snapshot?.capturedAt == old.capturedAt, "failure retains previous successful capture time")
        check(failedRecord?.lastAttemptAt == now, "failure retains most recent attempt time")
        check(failedRecord?.lastError != nil, "failure is visible without replacing old values")
        check(await failingProvider.calls == 1, "permanent failure is not retried")
        check(await failed.openedPopover(settings: autoSettings) == 0, "failure remains on auto-open cooldown")
        check(await failed.requestRefresh(a), "manual refresh can bypass failure cooldown")
    } catch {
        check(false, "coordinator setup should succeed: \(error)")
    }
}
