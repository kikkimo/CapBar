import Foundation
@testable import CapBarCore

@MainActor func runStorageChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appendingPathComponent("settings.json")
    let snapshotsURL = root.appendingPathComponent("snapshots.json")
    let firstSettingsStore = SettingsStore(url: settingsURL)

    do {
        var settings = try await firstSettingsStore.loadOrSeed()
        check(settings.accounts.contains(AccountID(provider: .claude, directory: "~/.claude")), "first run seeds default Claude directory")
        check(settings.accounts.contains(AccountID(provider: .codex, directory: "~/.codex")), "first run seeds default Codex directory")
        check(settings.autoRefreshOnOpen == false, "auto refresh defaults off")
        check(settings.refreshThresholdMinutes == 5, "shared threshold defaults to 5 minutes")
        check(settings.popoverSize.width == 448 && settings.popoverSize.height == 620, "popover defaults to the current minimum size")
        let initialFile = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        let initialValues = initialFile?["settings"] as? [String: Any]
        check(initialValues?["usageStatisticsEnabled"] as? Bool == false, "usage statistics default off in saved settings")
        check(initialValues?["samplingIntervalHours"] as? Int == 4, "sampling interval defaults to four hours")
        check(settings.planOverrides.isEmpty, "plan calibration starts empty rather than guessing ambiguous subscriptions")
        let calibratedAccount = AccountID(provider: .claude, directory: "~/.claude-example")
        settings.planOverrides = [UsagePlanOverride(account: calibratedAccount, tier: .claudeTeamPremium)]
        settings.popoverSize = PopoverSize(width: 720, height: 780)
        settings.accounts.removeAll { $0.provider == .claude }
        try await firstSettingsStore.save(settings)
        let newStore = SettingsStore(url: settingsURL)
        let restored = try await newStore.loadOrSeed()
        check(!restored.accounts.contains { $0.provider == .claude }, "removed default directory stays removed after restart")
        check(restored.popoverSize.width == 720 && restored.popoverSize.height == 780, "custom popover size survives restart")
        check(restored.planOverrides.first?.account == calibratedAccount
              && restored.planOverrides.first?.tier == .claudeTeamPremium,
              "per-account subscription calibration survives settings restart")
        check(PopoverSize(width: 100, height: 200).width == 448 && PopoverSize(width: 100, height: 200).height == 620, "popover size clamps both minimums")
        let legacy = #"{"schemaVersion":1,"settings":{"accounts":[],"defaultsSeeded":true,"autoRefreshOnOpen":false,"refreshThresholdMinutes":5}}"#
        try Data(legacy.utf8).write(to: settingsURL, options: .atomic)
        let migrated = try await SettingsStore(url: settingsURL).loadOrSeed()
        check(migrated.popoverSize.width == 448 && migrated.popoverSize.height == 620, "existing settings without dimensions migrate to defaults")
        try await SettingsStore(url: settingsURL).save(migrated)
        let migratedFile = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        let migratedValues = migratedFile?["settings"] as? [String: Any]
        check(migratedValues?["usageStatisticsEnabled"] as? Bool == false, "legacy settings migrate with statistics off")
        check(migratedValues?["samplingIntervalHours"] as? Int == 4, "legacy settings migrate with four-hour interval")
        check(migrated.planOverrides.isEmpty, "legacy settings gain an empty plan calibration list")
        let mode = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "settings file is private to current user")

        let activation = #"{"schemaVersion":1,"settings":{"accounts":[],"defaultsSeeded":true,"autoRefreshOnOpen":false,"refreshThresholdMinutes":5,"usageStatisticsEnabled":true,"samplingIntervalHours":3,"samplingScheduleStartedAt":"2026-09-28T12:00:00Z"}}"#
        try Data(activation.utf8).write(to: settingsURL, options: .atomic)
        let activeSettings = try await SettingsStore(url: settingsURL).loadOrSeed()
        try await SettingsStore(url: settingsURL).save(activeSettings)
        let activeFile = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        let activeValues = activeFile?["settings"] as? [String: Any]
        check(activeValues?["samplingScheduleStartedAt"] as? String == "2026-09-28T12:00:00Z", "sampling activation survives restart before first scheduled probe")

        let invalid = #"{"schemaVersion":1,"settings":{"accounts":[],"defaultsSeeded":true,"autoRefreshOnOpen":false,"refreshThresholdMinutes":5,"usageStatisticsEnabled":true,"samplingIntervalHours":5}}"#
        try Data(invalid.utf8).write(to: settingsURL, options: .atomic)
        do {
            _ = try await SettingsStore(url: settingsURL).loadOrSeed()
            check(false, "unsupported five-hour interval must be rejected")
        } catch {
            check(true, "unsupported sampling interval is rejected")
        }
    } catch {
        check(false, "settings round trip should succeed: \(error)")
    }

    let snapshots = SnapshotStore(url: snapshotsURL)
    let firstID = AccountID(provider: .claude, directory: "~/.claude-first")
    let secondID = AccountID(provider: .claude, directory: "~/.claude-second")
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = AccountIdentity(email: "shared@example.com", plan: "Team", organization: "Org")
    let snapshot = UsageSnapshot(identity: identity, windows: [], capturedAt: stamp)
    let first = AccountRecord(id: firstID, snapshot: snapshot, lastAttemptAt: stamp.addingTimeInterval(60), lastError: "timeout")
    let second = AccountRecord(id: secondID, snapshot: snapshot, lastAttemptAt: nil, lastError: nil)
    do {
        async let writeFirst: Void = snapshots.update(first)
        async let writeSecond: Void = snapshots.update(second)
        try await writeFirst
        try await writeSecond
        let loaded = try await SnapshotStore(url: snapshotsURL).load()
        check(loaded.count == 2, "concurrent writes retain both account records")
        check(loaded[firstID]?.snapshot?.identity.email == "shared@example.com", "first identity survives serialization")
        check(loaded[secondID]?.snapshot?.identity.email == "shared@example.com", "same email does not collapse accounts")
        check(loaded[firstID]?.snapshot?.capturedAt == stamp, "failure does not replace capturedAt")
        check(loaded[firstID]?.lastAttemptAt == stamp.addingTimeInterval(60), "last attempt is independent of capture")
        let data = try Data(contentsOf: snapshotsURL)
        let text = String(decoding: data, as: UTF8.self)
        check(text.contains("schemaVersion"), "snapshot file is versioned")
        check(!text.contains("oauthToken"), "snapshot file excludes credential fields")
        let mode = try FileManager.default.attributesOfItem(atPath: snapshotsURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "snapshot file is private to current user")
    } catch {
        check(false, "snapshot round trip should succeed: \(error)")
    }

    do {
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: snapshotsURL, options: .atomic)
        do {
            _ = try await SnapshotStore(url: snapshotsURL).load()
            check(false, "corrupt snapshots must be rejected")
        } catch {
            check(true, "corrupt snapshots rejected")
        }
        let bytes = try Data(contentsOf: snapshotsURL)
        check(bytes == corrupt, "corrupt file is not overwritten")
    } catch {
        check(false, "corrupt-file setup failed: \(error)")
    }
}
