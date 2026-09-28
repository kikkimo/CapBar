import Foundation
@testable import CapBarCore

private actor GatedTrendLoader {
    let samples: [UsageHistorySample]
    let laterSamples: [UsageHistorySample]?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    init(samples: [UsageHistorySample], laterSamples: [UsageHistorySample]? = nil) {
        self.samples = samples
        self.laterSamples = laterSamples
    }

    func load(account: AccountID, from: Date, through: Date) async -> [UsageHistorySample] {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { waiter = $0 }
        }
        return calls == 1 ? samples : laterSamples ?? samples
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor func runViewModelChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let snapshotStore = SnapshotStore(url: root.appendingPathComponent("snapshots.json"))
        let settings = try await settingsStore.loadOrSeed()
        let coordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [:], policy: ProbePolicy.bundled())
        let model = CapBarViewModel(settings: settings, settingsStore: settingsStore, coordinator: coordinator)
        var reported: [PopoverSize] = []
        model.onPopoverSizeChange = { reported.append($0) }
        model.setPopoverWidth(703)
        model.setPopoverHeight(823)
        check(model.settings.popoverSize.width == 703 && model.settings.popoverSize.height == 823, "exact size values update the model without rounding")
        check(reported.map(\.width) == [703, 703] && reported.map(\.height) == [620, 823], "each size edit resizes the live popover")
        model.setPopoverWidth(10)
        model.setPopoverHeight(10)
        check(model.settings.popoverSize.width == 448 && model.settings.popoverSize.height == 620, "UI edits respect the minimum dimensions")
        await model.flushSettings()
        let saved = try await SettingsStore(url: root.appendingPathComponent("settings.json")).loadOrSeed()
        check(saved.popoverSize.width == 448 && saved.popoverSize.height == 620, "size edits persist to settings JSON")

        reported.removeAll()
        model.editPopoverWidthInput("7")
        check(model.settings.popoverSize.width == 448 && reported.isEmpty, "partial width typing does not resize the popover")
        model.editPopoverWidthInput("703")
        model.commitPopoverWidthInput(maximum: 1200)
        check(model.settings.popoverSize.width == 703 && model.popoverWidthInput == "703", "return or focus loss applies an exact width")
        model.editPopoverWidthInput("not a number")
        model.commitPopoverWidthInput(maximum: 1200)
        check(model.settings.popoverSize.width == 703 && model.popoverWidthInput == "703", "invalid width input reverts without resizing")
        model.setPopoverWidth(713)
        check(model.settings.popoverSize.width == 713 && model.popoverWidthInput == "713", "width stepper applies immediately and syncs its text")
        model.editPopoverHeightInput("8")
        check(model.settings.popoverSize.height == 620, "partial height typing does not resize the popover")
        model.editPopoverHeightInput("823")
        model.commitPopoverHeightInput(maximum: 1000)
        check(model.settings.popoverSize.height == 823 && model.popoverHeightInput == "823", "return or focus loss applies an exact height")
        let pendingWidth = min(731, model.maximumPopoverWidth)
        let pendingHeight = min(851, model.maximumPopoverHeight)
        model.editPopoverWidthInput(String(pendingWidth))
        model.editPopoverHeightInput(String(pendingHeight))
        model.closed()
        check(model.settings.popoverSize.width == pendingWidth && model.settings.popoverSize.height == pendingHeight,
              "closing the popover commits pending size inputs within screen bounds")
        model.editPopoverWidthInput("9999")
        model.editPopoverHeightInput("9999")
        model.closed()
        check(model.settings.popoverSize.width == model.maximumPopoverWidth && model.settings.popoverSize.height == model.maximumPopoverHeight,
              "closing the popover clamps oversized pending inputs to screen bounds")

        var pickerEvents: [String] = []
        model.onFolderPickerWillOpen = { pickerEvents.append("opened") }
        var returned = 0
        model.onFolderPickerFinished = { returned += 1 }
        model.showsSettings = true
        model.prepareDirectorySelection()
        check(pickerEvents == ["opened"], "folder picker announces its opening before display")
        model.finishDirectorySelection(URL(fileURLWithPath: "/tmp/example-claude"))
        check(model.directoryInput == "/tmp/example-claude", "chosen folder fills the directory field")
        check(model.showsSettings && returned == 1, "folder picker returns to the settings popover")
        model.prepareDirectorySelection()
        model.finishDirectorySelection(nil)
        check(returned == 2 && model.showsSettings, "cancelling the picker also restores normal popover behavior")

        let enabledAt = Date(timeIntervalSince1970: 1_800_000_000)
        var samplingChanges: [UserSettings] = []
        model.onSamplingSettingsChange = { samplingChanges.append($0) }
        check(!model.settings.usageStatisticsEnabled && !model.showsTrend, "statistics and trend view start disabled")
        model.setUsageStatisticsEnabled(true, now: enabledAt)
        check(model.settings.usageStatisticsEnabled && model.settings.samplingScheduleStartedAt == enabledAt, "enabling statistics records first-schedule time")
        model.setTrendMode(true)
        check(model.showsTrend, "trend mode is available while statistics are enabled")
        model.setSamplingInterval(6, now: enabledAt.addingTimeInterval(60))
        check(model.settings.samplingIntervalHours == 6, "six-hour sampling choice applies")
        check(model.settings.samplingScheduleStartedAt == enabledAt.addingTimeInterval(60), "interval change realigns first UTC sample")
        model.setSamplingInterval(5, now: enabledAt.addingTimeInterval(120))
        check(model.settings.samplingIntervalHours == 6, "unsupported stepper value is ignored")
        model.setUsageStatisticsEnabled(false, now: enabledAt.addingTimeInterval(180))
        check(!model.showsTrend && !model.settings.usageStatisticsEnabled, "disabling statistics returns to quota view")
        check(samplingChanges.count == 3, "only accepted settings changes notify scheduler")
        await model.flushSettings()
        let usageSaved = try await SettingsStore(url: root.appendingPathComponent("settings.json")).loadOrSeed()
        check(!usageSaved.usageStatisticsEnabled && usageSaved.samplingIntervalHours == 6, "statistics choice and interval persist")

        let historyStore = UsageHistoryStore(url: root.appendingPathComponent("trend-history.sqlite3"))
        let account = AccountID(provider: .claude, directory: root.appendingPathComponent("trend-account").path)
        let chartEnd = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 7_200) * 7_200)
        let initial = UsageSnapshot(
            identity: AccountIdentity(email: "chart@example.com", plan: nil, organization: nil),
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 70, resetsAt: chartEnd.addingTimeInterval(86_400))],
            capturedAt: chartEnd.addingTimeInterval(-7_200)
        )
        let latest = UsageSnapshot(
            identity: initial.identity,
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 60, resetsAt: chartEnd.addingTimeInterval(86_400))],
            capturedAt: chartEnd
        )
        _ = try await historyStore.append(account: account, snapshot: initial)
        _ = try await historyStore.append(account: account, snapshot: latest)
        try await snapshotStore.update(AccountRecord(id: account, snapshot: latest, lastAttemptAt: chartEnd, lastError: nil))
        let trendCoordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [:], policy: ProbePolicy.bundled())
        let trendSettings = UserSettings(accounts: [account], defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5, usageStatisticsEnabled: true)
        let trendModel = CapBarViewModel(settings: trendSettings, settingsStore: settingsStore, coordinator: trendCoordinator, historyStore: historyStore)
        trendModel.setTrendMode(true, reload: false)
        await trendModel.reloadTrends(endingAt: chartEnd)
        check(trendModel.trends[account]?.points.last?.usedPercent == 10, "view model loads the latest two-hour usage from SQLite")

        let gated = GatedTrendLoader(samples: [
            UsageHistorySample(capturedAt: initial.capturedAt, usedPercent: 30, resetsAt: chartEnd.addingTimeInterval(86_400)),
            UsageHistorySample(capturedAt: latest.capturedAt, usedPercent: 40, resetsAt: chartEnd.addingTimeInterval(86_400))
        ])
        let gatedModel = CapBarViewModel(
            settings: trendSettings, settingsStore: settingsStore,
            coordinator: trendCoordinator, historyStore: historyStore
        )
        gatedModel.historySampleLoader = { account, start, end in
            await gated.load(account: account, from: start, through: end)
        }
        gatedModel.setTrendMode(true, reload: false)
        let firstLoad = Task { await gatedModel.reloadTrends(endingAt: chartEnd) }
        for _ in 0..<100 {
            if await gated.calls > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        gatedModel.setTrendMode(false)
        await gated.release()
        await firstLoad.value
        gatedModel.setTrendMode(true, reload: false)
        await gatedModel.reloadTrends(endingAt: chartEnd)
        check(gatedModel.trends[account]?.points.last?.usedPercent == 10,
              "turning trend mode back on reloads after an earlier load was discarded")

        let oldSamples = [
            UsageHistorySample(capturedAt: initial.capturedAt, usedPercent: 30, resetsAt: chartEnd.addingTimeInterval(86_400)),
            UsageHistorySample(capturedAt: latest.capturedAt, usedPercent: 40, resetsAt: chartEnd.addingTimeInterval(86_400))
        ]
        let newSamples = [
            oldSamples[0],
            UsageHistorySample(capturedAt: latest.capturedAt, usedPercent: 50, resetsAt: chartEnd.addingTimeInterval(86_400))
        ]
        let overlapLoader = GatedTrendLoader(samples: oldSamples, laterSamples: newSamples)
        let overlapModel = CapBarViewModel(
            settings: trendSettings, settingsStore: settingsStore,
            coordinator: trendCoordinator, historyStore: historyStore
        )
        overlapModel.historySampleLoader = { account, start, end in
            await overlapLoader.load(account: account, from: start, through: end)
        }
        overlapModel.setTrendMode(true, reload: false)
        let olderLoad = Task { await overlapModel.reloadTrends(endingAt: chartEnd) }
        for _ in 0..<100 {
            if await overlapLoader.calls > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await overlapModel.reloadTrends(endingAt: chartEnd)
        check(overlapModel.trends[account]?.points.last?.usedPercent == 20,
              "newer overlapping trend load publishes its result")
        await overlapLoader.release()
        await olderLoad.value
        check(overlapModel.trends[account]?.points.last?.usedPercent == 20,
              "older overlapping trend load cannot overwrite the newer result")
    } catch {
        check(false, "view model checks setup succeeds: \(error)")
    }
}
