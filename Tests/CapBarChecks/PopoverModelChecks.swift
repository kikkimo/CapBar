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
        let fiveOnlyExhausted = PopoverAccountRow(
            account: claude, title: "person@example.com", subtitle: "Example · Team",
            directoryLabel: "~/.claude-a", timeLabel: "刚刚", captureAgeBand: .fresh,
            windows: [try QuotaWindow(kind: .fiveHour, remainingPercent: 0, resetsAt: now.addingTimeInterval(600)), week],
            isRefreshing: false, error: nil
        )
        check(!fiveOnlyExhausted.isExhausted, "5-hour-only exhaustion does not mark the whole account exhausted")
        let expiredWeek = try QuotaWindow(kind: .sevenDay, remainingPercent: 0, resetsAt: Date().addingTimeInterval(-60))
        let expiredRow = PopoverAccountRow(
            account: codex, title: "codex@example.com", subtitle: "Pro",
            directoryLabel: "~/.codex-b", timeLabel: "1 小时前", captureAgeBand: .old,
            windows: [expiredWeek], isRefreshing: false, error: nil
        )
        check(!expiredRow.isExhausted, "expired weekly reset does not keep the account in the exhausted state")
        check(SevenDayResetState(resetsAt: now.addingTimeInterval(7 * 86_400), now: now) == .upcoming(0),
              "new seven-day cycle starts with an empty time ring")
        check(SevenDayResetState(resetsAt: now.addingTimeInterval(3.5 * 86_400), now: now) == .upcoming(0.5),
              "halfway through the weekly cycle fills half of the time ring")
        check(SevenDayResetState(resetsAt: nil, now: now) == .unknown,
              "unknown weekly reset time does not invent ring progress")
        check(SevenDayResetState(resetsAt: now, now: now) == .awaitingRefresh,
              "ring disappears at the exact reset time until a new snapshot arrives")
        check(!PopoverLayout.usesWideRows(width: 448) && PopoverLayout.usesWideRows(width: 640), "account row layout changes at the wide breakpoint")
    } catch {
        check(false, "popover rows should map: \(error)")
    }
}
