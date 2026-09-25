import Foundation
@testable import CapBarCore

@MainActor func runAppIntegrationChecks() async {
    do {
        let settingsStore = SettingsStore()
        let snapshotStore = SnapshotStore()
        let settings = try await settingsStore.loadOrSeed()
        let coordinator = try await RefreshCoordinator(
            settingsStore: settingsStore,
            snapshotStore: snapshotStore,
            providers: [.claude: ClaudeClient(), .codex: CodexClient()],
            policy: ProbePolicy.bundled()
        )
        check(!settings.accounts.isEmpty, "app has accounts configured")
        let started = await coordinator.requestRefreshAll(settings: settings)
        check(started == settings.accounts.count, "manual all refresh starts every idle account")
        let deadline = Date().addingTimeInterval(210)
        while Date() < deadline {
            let view = await coordinator.viewState()
            if view.refreshing.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let view = await coordinator.viewState()
        check(view.refreshing.isEmpty, "all probes finish and loading clears")
        let rows = PopoverPresentation.rows(settings: settings, state: view, now: Date(), calendar: .current)
        for row in rows {
            let record = view.records[row.account]
            print("\(row.account.provider.rawValue) \(row.directoryLabel): \(row.windows.count) windows; error=\(record?.lastError ?? "none")")
            check(!row.windows.isEmpty, "\(row.account.provider.rawValue) snapshot reaches the popover")
            check(record?.snapshot?.capturedAt != nil, "\(row.account.provider.rawValue) capture time persists")
        }
        let stored = try await snapshotStore.load()
        for account in settings.accounts {
            check(stored[account]?.snapshot?.windows.isEmpty == false, "\(account.provider.rawValue) snapshot survives store reload")
        }
    } catch {
        check(false, "app integration setup succeeds: \(error)")
    }
}
