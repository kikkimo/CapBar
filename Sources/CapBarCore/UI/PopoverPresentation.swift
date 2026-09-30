import Foundation

enum SevenDayResetState: Equatable {
    case unknown
    case upcoming(Double)
    case awaitingRefresh

    init(resetsAt: Date?, now: Date) {
        guard let resetsAt else { self = .unknown; return }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { self = .awaitingRefresh; return }
        self = .upcoming(min(1, max(0, 1 - remaining / (7 * 86_400))))
    }
}

struct PopoverAccountRow: Sendable {
    let account: AccountID
    let title: String
    let subtitle: String
    let directoryLabel: String
    let timeLabel: String
    let captureAgeBand: CaptureAgeBand
    let windows: [QuotaWindow]
    let isRefreshing: Bool
    let error: String?
    var detectedPlan: String? = nil

    var refreshEnabled: Bool { !isRefreshing }
    var isExhausted: Bool {
        windows.contains { window in
            window.kind == .sevenDay && window.remainingPercent == 0 &&
                SevenDayResetState(resetsAt: window.resetsAt, now: Date()) != .awaitingRefresh
        }
    }
}

enum PopoverLayout {
    static func usesWideRows(width: Int) -> Bool { width >= 640 }
}

enum PopoverPresentation {
    static func rows(
        settings: UserSettings,
        state: CoordinatorViewState,
        now: Date,
        calendar: Calendar
    ) -> [PopoverAccountRow] {
        settings.accounts.map { account in
            let record = state.records[account]
            let identity = record?.snapshot?.identity
            let details = [identity?.organization, identity?.plan].compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = account.directory == home ? "~" :
                account.directory.hasPrefix(home + "/") ? "~" + account.directory.dropFirst(home.count) : account.directory
            return PopoverAccountRow(
                account: account,
                title: identity?.email.flatMap { $0.isEmpty ? nil : $0 } ?? "尚未识别",
                subtitle: details.isEmpty ? "待识别" : details.joined(separator: " · "),
                directoryLabel: path,
                timeLabel: capturedAtLabel(record?.snapshot?.capturedAt, now: now, calendar: calendar),
                captureAgeBand: captureAgeBand(record?.snapshot?.capturedAt, now: now),
                windows: record?.snapshot?.windows ?? [],
                isRefreshing: state.refreshing.contains(account),
                error: record?.lastError,
                detectedPlan: identity?.plan
            )
        }
    }

    static func exhaustedCount(rows: [PopoverAccountRow]) -> Int {
        rows.filter(\.isExhausted).count
    }
}
