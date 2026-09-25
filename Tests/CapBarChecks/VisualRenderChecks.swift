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
        AccountID(provider: .claude, directory: "~/.claude-team"),
        AccountID(provider: .claude, directory: "~/.claude-shared"),
        AccountID(provider: .codex, directory: "~/.codex"),
        AccountID(provider: .codex, directory: "~/.codex-work"),
    ]
    let settings = UserSettings(accounts: accounts, defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5)
    try await settingsStore.save(settings)
    let now = Date()
    let samples: [(String, String, String?, Double, Double?, Int)] = [
        ("adrian@example.com", "Team", "Example Studio", 0, 99, 2),
        ("liubin@example.com", "Team", "Example Studio", 33, 33, 7),
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
    print("Rendered /tmp/capbar-preview-{light,dark,settings,wide,settings-wide,states}.png")
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
