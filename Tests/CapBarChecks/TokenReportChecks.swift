import AppKit
import Foundation
@testable import CapBarCore

@MainActor func runTokenReportChecks() async {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let date = ISO8601DateFormatter().date(from: "2026-10-26T01:00:00Z")!
    let a = AccountID(provider: .claude, directory: "/tmp/report-personal"), b = AccountID(provider: .codex, directory: "/tmp/report-work")
    let events = [TokenUsageEvent(id: "a", account: a, timestamp: date, model: "claude-sonnet", tokens: TokenCounts(input: 900, output: 10), apiCost: 0.2),
                  TokenUsageEvent(id: "b", account: b, timestamp: date, model: "gpt-5", tokens: TokenCounts(input: 100, output: 20), apiCost: 2)]
    let labels = [a: "studio@example.com", b: "builder@example.com"]
    var query = TokenReportQuery(range: .preset(.sevenDays, now: date, calendar: calendar))
    func result(_ q: TokenReportQuery) -> TokenReportResult { .build(events: events, sources: [a,b], labels: labels, query: q, calendar: calendar) }
    check(result(query).rows.count == 2 && result(query).accountCount == 2, "report begins with date/account/model detail rows")
    query.search = "BUILDER gPt"
    check(result(query).rows.map(\.id) == ["b"], "search is case-insensitive and matches all words across account/model fields")
    check(result(query).total.tokens.total == 120 && result(query).total.knownCost == 2, "report totals reflect the search result rather than hidden rows")
    query.search = "report-personal"; query.scope = .model
    check(result(query).rows.count == 1 && result(query).rows[0].primary == "claude-sonnet", "path search is applied before model aggregation")
    query.search = ""; query.scope = .detail; query.account = a
    check(result(query).total.tokens.total == 910, "report account filter excludes other account paths")
    query.account = nil; query.provider = .codex
    check(result(query).rows.count == 1 && result(query).modelCount == 1, "report tool filter scopes both rows and summary cards")
    query.provider = nil
    let rows = result(query).rows
    check(rows.sorted(using: KeyPathComparator(\.total)).map(\.id) == ["b", "a"], "token columns sort numerically rather than as formatted strings")
    check(rows.sorted(using: KeyPathComparator(\.cost, order: .reverse)).map(\.id) == ["b", "a"], "amount sorts numerically and supports reverse order")
    for scope in TokenReportScope.allCases {
        query.scope = scope
        check(result(query).rows.reduce(Int64(0)) { $0 + $1.total } == 1030, "\(scope.rawValue) grouping preserves filtered token totals")
    }
    query.end = calendar.date(byAdding: .day, value: -1, to: query.start)!
    check(result(query).rows.isEmpty, "invalid date range cannot silently expand the report")
    query = TokenReportQuery(range: .preset(.today, now: date, calendar: calendar))
    let unchecked = TokenReportResult.build(events: events, sources: [a], labels: labels, query: query, calendar: calendar)
    check(unchecked.rows.count == 1 && unchecked.total.tokens.total == 910, "unchecked sources stay excluded from independent report queries")
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = TokenUsageController(scanner: TokenLogScanner(cacheURL: root.appendingPathComponent("unused.json")), accounts: [a,b], operation: { _, now in TokenScanResult(events: events, lastSuccess: now) })
    source.select(period: .today, now: date); await source.scan(now: date)
    let originalRange = source.range
    let windowController = TokenUsageReportWindowController(source: source, labels: labels)
    let originalWindow = windowController.window!
    let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    let content = originalWindow.contentLayoutRect.size
    check(abs(content.width - min(1680, screen.width - 64)) < 1 && abs(content.height - min(1000, screen.height - 64)) < 1, "report defaults to a larger 1680 by 1000 content area bounded by available screen space (actual \(content), screen \(screen))")
    let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 462, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    main.isReleasedWhenClosed = false; main.orderFront(nil)
    windowController.show()
    originalWindow.contentView?.layoutSubtreeIfNeeded(); originalWindow.displayIfNeeded()
    try? await Task.sleep(for: .milliseconds(40))
    check(abs(originalWindow.contentLayoutRect.width - content.width) < 1 && abs(originalWindow.contentLayoutRect.height - content.height) < 1, "hosting layout must not shrink the larger report after it is shown")
    check(NSApplication.shared.modalWindow == nil && originalWindow.sheetParent == nil && originalWindow.parent == nil, "report is a standalone nonmodal window without a popover or sheet parent")
    check(originalWindow.styleMask.contains(.resizable) && originalWindow.styleMask.contains(.closable) && originalWindow.level == .normal, "report has standard resize and close controls at normal window level")
    windowController.report.query.search = "builder"; windowController.report.query.select(.thirtyDays, now: date, calendar: calendar)
    check(source.period == .today && source.range == originalRange && source.account == nil, "report search and date changes do not mutate the main usage selection")
    source.select(provider: .claude)
    check(windowController.report.query.provider == nil && windowController.report.result.rows.count == 1, "main tool changes do not overwrite independent report filters")
    originalWindow.performClose(nil)
    check(!originalWindow.isVisible && main.isVisible, "closing report leaves the main window operational")
    windowController.show()
    check(windowController.window === originalWindow && originalWindow.isVisible && windowController.report.query.search == "builder", "reopening focuses one reusable report and retains its query")
    windowController.report.labels[b] = "updated@example.com"
    windowController.report.query.search = "updated"
    check(windowController.report.result.rows.count == 1 && windowController.report.result.rows[0].account == "updated@example.com", "identity updates refresh account names and searchable labels in an already open report")
    originalWindow.close(); main.close()

}
