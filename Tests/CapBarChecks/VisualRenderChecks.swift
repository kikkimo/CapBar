import AppKit
import SwiftUI
@testable import CapBarCore

private actor PreviewHangingProvider: UsageProvider {
    func probe(account: AccountID) async throws -> UsageSnapshot {
        try await Task.sleep(for: .seconds(60))
        throw ProbeFailure.transient("preview only")
    }
}

@MainActor func renderPopoverPreview() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let settingsStore = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    let snapshotStore = SnapshotStore(url: folder.appendingPathComponent("snapshots.json"))
    let accounts = [
        AccountID(provider: .claude, directory: "~/.claude-personal"),
        AccountID(provider: .claude, directory: "~/.claude-team"),
        AccountID(provider: .codex, directory: "~/.codex"),
        AccountID(provider: .codex, directory: "~/.codex-work"),
    ]
    let settings = UserSettings(accounts: accounts, defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5)
    try await settingsStore.save(settings)
    let now = Date()
    let samples: [(String, String, String?, Double, Double?, Int)] = [
        ("alex@example.com", "Team", "Example Studio", 0, 99, 2),
        ("sam@example.com", "Team", "Example Studio", 33, 33, 7),
        ("codex@example.com", "Plus", nil, 68, 42, 64),
        ("work@example.com", "Team", "Example Org", 13, nil, 180),
    ]
    var snapshots: [UsageSnapshot] = []
    for (account, sample) in zip(accounts, samples) {
        var windows = [try QuotaWindow(kind: .fiveHour, remainingPercent: sample.3, resetsAt: now.addingTimeInterval(2 * 3600))]
        if let seven = sample.4 {
            windows.append(try QuotaWindow(kind: .sevenDay, remainingPercent: seven, resetsAt: now.addingTimeInterval(4 * 86400)))
        }
        let snapshot = UsageSnapshot(
            identity: AccountIdentity(email: sample.0, plan: sample.1, organization: sample.2),
            windows: windows,
            capturedAt: now.addingTimeInterval(-Double(sample.5) * 60)
        )
        snapshots.append(snapshot)
        try await snapshotStore.update(AccountRecord(id: account, snapshot: snapshot, lastAttemptAt: snapshot.capturedAt, lastError: nil))
    }
    let coordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [:], policy: ProbePolicy.bundled())
    let model = CapBarViewModel(settings: settings, settingsStore: settingsStore, coordinator: coordinator)
    model.updateRows()
    for _ in 0..<100 where model.rows.count != accounts.count {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard model.rows.count == accounts.count else { throw NSError(domain: "CapBarVisual", code: 1) }

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        try render(model: model, appearance: appearance, to: URL(fileURLWithPath: "/tmp/capbar-preview-\(name).png"))
    }
    model.showsSettings = true
    try render(model: model, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-settings.png"))
    model.setPopoverSize(width: 720, height: 800)
    model.showsSettings = false
    try render(model: model, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-wide.png"))
    model.showsSettings = true
    try render(model: model, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-settings-wide.png"))

    let historyStore = UsageHistoryStore(url: folder.appendingPathComponent("preview-history.sqlite3"))
    let gridEnd = floor(now.timeIntervalSince1970 / (2 * 3_600)) * (2 * 3_600)
    func weightedUsed(_ index: Int, count: Int, start: Double, end: Double, spike: Int) -> Double {
        let weights = (1...count).map { step in
            step == spike ? 22.0 : step % 12 == 0 ? 5.0 : step % 5 == 0 ? 2.5 : 0.6
        }
        let completed = weights.prefix(index).reduce(0, +)
        return start + (end - start) * completed / weights.reduce(0, +)
    }
    for (account, snapshot) in zip(accounts, snapshots) {
        guard let weekly = snapshot.windows.first(where: { $0.kind == .sevenDay }) else { continue }
        let currentUsed = 100 - weekly.remainingPercent
        let hasReset = account == accounts[1]
        let resetAt = Date(timeIntervalSince1970: gridEnd - 60 * 3_600)
        for index in 0...84 {
            if account == accounts[2] && (27...32).contains(index) { continue }
            let used: Double
            let nextReset: Date
            if hasReset && index < 54 {
                used = weightedUsed(index, count: 53, start: 12, end: 90, spike: 37)
                nextReset = resetAt
            } else if hasReset {
                used = weightedUsed(index - 54, count: 30, start: 2, end: currentUsed, spike: 22)
                nextReset = resetAt.addingTimeInterval(7 * 86_400)
            } else {
                used = weightedUsed(index, count: 84, start: 0, end: currentUsed, spike: 38)
                nextReset = weekly.resetsAt ?? now.addingTimeInterval(4 * 86_400)
            }
            let historySnapshot = UsageSnapshot(
                identity: snapshot.identity,
                windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 100 - used, resetsAt: nextReset)],
                capturedAt: Date(timeIntervalSince1970: gridEnd - Double(84 - index) * 2 * 3_600)
            )
            _ = try await historyStore.append(account: account, snapshot: historySnapshot)
        }
    }
    let trendSettings = UserSettings(
        accounts: accounts, defaultsSeeded: true, autoRefreshOnOpen: false,
        refreshThresholdMinutes: 5, usageStatisticsEnabled: true
    )
    let trendSnapshotStore = SnapshotStore(url: folder.appendingPathComponent("trend-snapshots.json"))
    for (index, account) in accounts.enumerated() {
        let snapshot = snapshots[index]
        let displaySnapshot: UsageSnapshot
        if index == 0 {
            displaySnapshot = UsageSnapshot(
                identity: snapshot.identity,
                windows: [try QuotaWindow(kind: .fiveHour, remainingPercent: 72, resetsAt: snapshot.windows[0].resetsAt),
                          snapshot.windows[1]],
                capturedAt: snapshot.capturedAt
            )
        } else {
            displaySnapshot = snapshot
        }
        try await trendSnapshotStore.update(AccountRecord(
            id: account, snapshot: displaySnapshot, lastAttemptAt: displaySnapshot.capturedAt, lastError: nil
        ))
    }
    let trendCoordinator = try await RefreshCoordinator(
        settingsStore: settingsStore, snapshotStore: trendSnapshotStore,
        providers: [:], policy: ProbePolicy.bundled()
    )
    let trendModel = CapBarViewModel(
        settings: trendSettings, settingsStore: settingsStore,
        coordinator: trendCoordinator, historyStore: historyStore
    )
    trendModel.updateRows()
    for _ in 0..<100 where trendModel.rows.count != accounts.count {
        try await Task.sleep(for: .milliseconds(10))
    }
    trendModel.setTrendMode(true, reload: false)
    await trendModel.reloadTrends()
    try render(model: trendModel, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-trend-light.png"))
    try render(model: trendModel, appearance: .darkAqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-trend-dark.png"))
    trendModel.setTrendMode(false)
    try render(model: trendModel, appearance: .darkAqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-quota-expanded.png"))
    trendModel.showsSettings = true
    try render(model: trendModel, appearance: .darkAqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-usage-settings.png"))

    let shortHistory = UsageHistoryStore(url: folder.appendingPathComponent("preview-short-history.sqlite3"))
    let shortAccount = accounts[1]
    let shortSnapshot = snapshots[1]
    for (minutesAgo, used) in [(50, 20.0), (25, 25.0), (0, 30.0)] {
        let sample = UsageSnapshot(
            identity: shortSnapshot.identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 100 - used, resetsAt: now.addingTimeInterval(4 * 86_400))],
            capturedAt: now.addingTimeInterval(-Double(minutesAgo) * 60)
        )
        _ = try await shortHistory.append(account: shortAccount, snapshot: sample)
    }
    let shortSettings = UserSettings(
        accounts: [shortAccount], defaultsSeeded: true, autoRefreshOnOpen: false,
        refreshThresholdMinutes: 5, usageStatisticsEnabled: true
    )
    let shortSampler = UsageSamplingController(coordinator: coordinator, now: { now })
    await shortSampler.start(settings: shortSettings)
    let shortModel = CapBarViewModel(
        settings: shortSettings, settingsStore: settingsStore, coordinator: coordinator,
        historyStore: shortHistory, samplingController: shortSampler
    )
    shortModel.updateRows()
    for _ in 0..<100 where shortModel.rows.count != 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    shortModel.setTrendMode(true, reload: false)
    await shortModel.reloadTrends(endingAt: now)
    try render(model: shortModel, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-trend-empty.png"))

    let singleHistory = UsageHistoryStore(url: folder.appendingPathComponent("preview-single-history.sqlite3"))
    let singleGridEnd = floor(now.timeIntervalSince1970 / (4 * 3_600)) * (4 * 3_600)
    let singleEnd = Date(timeIntervalSince1970: singleGridEnd + 5 * 60)
    let singleReset = Date(timeIntervalSince1970: singleGridEnd + 4 * 86_400)
    for (offset, used) in [(-4 * 3_600 - 23 * 60, 26.0), (-4 * 3_600 + 20, 26.0),
                           (-3_600 - 37 * 60, 27.0), (2 * 60, 28.0)] {
        let sample = UsageSnapshot(
            identity: shortSnapshot.identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 100 - used, resetsAt: singleReset)],
            capturedAt: Date(timeIntervalSince1970: singleGridEnd + Double(offset))
        )
        _ = try await singleHistory.append(account: shortAccount, snapshot: sample)
    }
    let singleModel = CapBarViewModel(
        settings: shortSettings, settingsStore: settingsStore, coordinator: coordinator,
        historyStore: singleHistory
    )
    singleModel.updateRows()
    for _ in 0..<100 where singleModel.rows.count != 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    singleModel.setTrendMode(true, reload: false)
    await singleModel.reloadTrends(endingAt: singleEnd)
    try render(model: singleModel, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-trend-single.png"))

    let stateStore = SnapshotStore(url: folder.appendingPathComponent("state-snapshots.json"))
    try await stateStore.update(AccountRecord(id: accounts[0], snapshot: snapshots[0], lastAttemptAt: now, lastError: nil))
    try await stateStore.update(AccountRecord(id: accounts[1], snapshot: snapshots[1], lastAttemptAt: now, lastError: "探测失败，请手动重试"))
    try await stateStore.update(AccountRecord(id: accounts[2], snapshot: snapshots[2], lastAttemptAt: now, lastError: nil))
    let stateCoordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: stateStore, providers: [.codex: PreviewHangingProvider()], policy: ProbePolicy.bundled())
    _ = await stateCoordinator.requestRefresh(accounts[2])
    let stateModel = CapBarViewModel(settings: settings, settingsStore: settingsStore, coordinator: stateCoordinator)
    stateModel.updateRows()
    for _ in 0..<100 where stateModel.rows.count != accounts.count {
        try await Task.sleep(for: .milliseconds(10))
    }
    try render(model: stateModel, appearance: .aqua, to: URL(fileURLWithPath: "/tmp/capbar-preview-states.png"))
    await stateCoordinator.cancelAll()
    print("Rendered /tmp/capbar-preview-{light,dark,settings,wide,settings-wide,states,trend-light,trend-dark,trend-empty,trend-single,quota-expanded,usage-settings}.png")
}

@MainActor private func render(model: CapBarViewModel, appearance: NSAppearance.Name, to url: URL) throws {
    let view = NSHostingView(rootView: CapBarPopoverView(model: model))
    view.appearance = NSAppearance(named: appearance)
    view.frame = NSRect(x: 0, y: 0, width: model.settings.popoverSize.width, height: model.settings.popoverSize.height)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(domain: "CapBarVisual", code: 2)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CapBarVisual", code: 3)
    }
    try data.write(to: url)
}
