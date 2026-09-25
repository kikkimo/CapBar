import Foundation
@testable import CapBarCore

@MainActor func runPopoverModelChecks() {
    do {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claude = AccountID(provider: .claude, directory: "~/.claude-a")
        let codex = AccountID(provider: .codex, directory: "~/.codex-b")
        let empty = AccountID(provider: .claude, directory: "~/.claude-empty")
        let identity = AccountIdentity(email: "person@example.com", plan: "Team", organization: "Example")
        let five = try QuotaWindow(kind: .fiveHour, remainingPercent: 24, resetsAt: now.addingTimeInterval(1200))
        let week = try QuotaWindow(kind: .sevenDay, remainingPercent: 78, resetsAt: now.addingTimeInterval(3600))
        let oldSnapshot = UsageSnapshot(identity: identity, windows: [five, week], capturedAt: now.addingTimeInterval(-17 * 60))
        let weeklySnapshot = UsageSnapshot(identity: AccountIdentity(email: "codex@example.com", plan: "Pro", organization: nil), windows: [week], capturedAt: now)
        let settings = UserSettings(accounts: [claude, codex, empty], defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5)
        let view = CoordinatorViewState(records: [
            claude: AccountRecord(id: claude, snapshot: oldSnapshot, lastAttemptAt: now, lastError: nil),
            codex: AccountRecord(id: codex, snapshot: weeklySnapshot, lastAttemptAt: now, lastError: "网络超时")
        ], refreshing: [claude])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let rows = PopoverPresentation.rows(settings: settings, state: view, now: now, calendar: calendar)
        check(rows.count == 3, "configured accounts retain order")
        check(rows[0].title == "person@example.com" && rows[0].subtitle == "Example · Team", "identity uses email then organization and plan")
        check(rows[0].timeLabel == "17 分钟前" && rows[0].isRefreshing, "loading keeps old capture time")
        check(rows[0].captureAgeBand == .underThirty, "row exposes a time color from its actual snapshot age")
        check(!rows[0].refreshEnabled && rows[0].windows.count == 2, "only loading account disables its refresh")
        check(rows[1].refreshEnabled && rows[1].error == "网络超时", "failed account retains snapshot and refresh action")
        check(rows[1].windows.count == 1 && rows[1].windows[0].kind == .sevenDay, "weekly-only account has no invented window")
        check(rows[2].title == "尚未识别" && rows[2].windows.isEmpty && rows[2].timeLabel == "尚未采集", "first-run account has empty state")
        check(rows[2].captureAgeBand == .unknown, "uncollected account does not show a misleading freshness color")
        check(PopoverPresentation.exhaustedCount(rows: rows) == 0, "header exhaustion count follows actual windows")
        check(!PopoverLayout.usesWideRows(width: 448) && PopoverLayout.usesWideRows(width: 640), "account row layout changes at the wide breakpoint")
    } catch {
        check(false, "popover rows should map: \(error)")
    }
}
