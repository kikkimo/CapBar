import Foundation
@testable import CapBarCore

@MainActor func runTokenUsageChecks() async {
    check(TokenDisplay.millions(5_425_000) == "5.42M" && TokenDisplay.millions(0) == "0M", "tooltip totals use millions without changing token counts")
    check(TokenDisplay.millions(120) == "<0.01M", "small nonzero totals never become a false zero")
    let account = AccountID(provider: .claude, directory: "/tmp/token-source")
    let report = #"{"version":"20.0.44","rows":[{"date":"2026-10-26","model":"claude-sonnet-4-5","input":100,"output":20,"cacheWrite":40,"cacheRead":300,"total":460,"cost":0.00084,"missingPricing":false}]}"#
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = ISO8601DateFormatter().date(from: "2026-10-26T14:00:00Z")!
    do {
        let events = try TokenLogScanner.decodeReport(Data(report.utf8), provider: .claude, account: account, calendar: calendar)
        check(events.count == 1 && events[0].tokens.total == 460, "bridge preserves upstream token buckets and reported total")
        check(events[0].apiCost == 0.00084, "Swift preserves ccusage cost without a second pricing implementation")
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = calendar.timeZone
        let buddhistEvents = try TokenLogScanner.decodeReport(Data(report.utf8), provider: .claude, account: account, calendar: buddhist)
        check(buddhistEvents[0].timestamp == events[0].timestamp, "ccusage Gregorian dates do not change with the system calendar")
        let range = TokenDateRange.preset(.today, now: now, calendar: calendar)
        let summary = TokenUsageSummary.build(events: events, range: range, provider: nil, calendar: calendar)
        check(summary.tokens.total == 460 && summary.daily.count == 1, "daily core buckets respect local date filters")
        check(summary.total.knownCost == 0.00084 && summary.total.pricedEvents == 1, "display aggregation preserves exact core amount")
        let filtered = TokenUsageSummary.build(events: events, range: range, provider: .codex, calendar: calendar)
        check(filtered.tokens.total == 0 && filtered.providers.isEmpty, "tool filter never includes another provider")
        let second = AccountID(provider: .claude, directory: "/tmp/second-account")
        var other = events[0]; other.account = second; other.id = "other"; other.model = "claude-opus"; other.tokens.input = 200; other.tokens.reportedTotal = 560
        let combined = TokenUsageSummary.build(events: events + [other], range: range, provider: nil, calendar: calendar)
        check(combined.accounts.count == 2 && combined.dailyByAccount.count == 2, "same-provider accounts retain independent daily contributions")
        check(combined.accounts.reduce(Int64(0)) { $0 + $1.tokens.total } == combined.tokens.total, "account contributions add up exactly to the displayed total")
        check(combined.models.count == 2 && combined.dailyByModel.count == 2, "model summary and hovered model detail use the same filtered rows")
        let single = TokenUsageSummary.build(events: events + [other], range: range, provider: nil, calendar: calendar, account: second)
        check(single.accounts.count == 1 && single.tokens.total == 560 && single.models.first?.label == "claude-opus", "account filter applies to totals, chart, tooltip and model summaries")
        let unknown = report.replacingOccurrences(of: "\"missingPricing\":false", with: "\"missingPricing\":true").replacingOccurrences(of: "\"cost\":0.00084", with: "\"cost\":0")
        let unknownEvents = try TokenLogScanner.decodeReport(Data(unknown.utf8), provider: .claude, account: account, calendar: calendar)
        let unknownSummary = TokenUsageSummary.build(events: unknownEvents, range: range, provider: nil, calendar: calendar)
        check(unknownSummary.tokens.total == 460 && unknownSummary.total.unpricedEvents == 1, "upstream missing-pricing marker preserves tokens")
        check(TokenDisplay.money(unknownSummary.total) == "—", "unknown amount is not rendered as zero dollars")
        var partialEvents = events; partialEvents[0].missingPricing = true
        let partialSummary = TokenUsageSummary.build(events: partialEvents, range: range, provider: nil, calendar: calendar)
        check(partialSummary.total.knownCost == 0.00084 && partialSummary.total.unpricedEvents == 1, "a core partial-pricing amount is preserved alongside its missing-pricing flag")
        checkThrows("unexpected engine version is rejected") { _ = try TokenLogScanner.decodeReport(Data(report.replacingOccurrences(of: "20.0.44", with: "0.0.0").utf8), provider: .claude, account: account) }
        checkThrows("corrupt core output is rejected") { _ = try TokenLogScanner.decodeReport(Data(report.replacingOccurrences(of: "\"input\":100", with: "\"input\":-1").utf8), provider: .claude, account: account) }
    } catch { check(false, "core JSON display adapter: \(error)") }
    let range = TokenDateRange.preset(.thirtyDays, now: now, calendar: calendar)
    check(calendar.dateComponents([.day], from: range.start, to: calendar.startOfDay(for: now)).day == 29, "30-day range includes today and previous 29 local dates")
    check(TokenDateRange.custom(start: now, end: now.addingTimeInterval(-86400), calendar: calendar) == nil, "reversed custom range rejected")
    check(TokenScanFreshness.classify(lastSuccess: now.addingTimeInterval(-1800), now: now, intervalMinutes: 30, automatic: true) == .fresh, "one scan interval remains fresh")
    check(TokenScanFreshness.classify(lastSuccess: now.addingTimeInterval(-1801), now: now, intervalMinutes: 30, automatic: true) == .delayed, "missing one interval marks delayed")
    check(TokenScanFreshness.classify(lastSuccess: now.addingTimeInterval(-3601), now: now, intervalMinutes: 30, automatic: true) == .stale, "missing two intervals marks stale")
    check(TokenScanFreshness.classify(lastSuccess: now.addingTimeInterval(-9000), now: now, intervalMinutes: 30, automatic: false) == .manual, "manual mode does not invent scheduling expiry")
}

@MainActor func runTokenScannerChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let home = root.appendingPathComponent("claude"), project = home.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let a = AccountID(provider: .claude, directory: home.path)
        let line = #"{"type":"assistant","timestamp":"2026-10-26T01:00:00Z","sessionId":"s","requestId":"r","message":{"id":"msg_1","model":"claude-sonnet-4-5","content":[{"type":"text","text":"private_user_prompt"}],"usage":{"input_tokens":100,"output_tokens":20}}}"#
        let file = project.appendingPathComponent("one.jsonl")
        try Data((line + "\n{broken\n").utf8).write(to: file)
        let cache = root.appendingPathComponent("cache.json")
        let scanner = TokenLogScanner(cacheURL: cache)
        let first = try await scanner.scan(accounts: [a], now: Date(timeIntervalSince1970: 100))
        check(first.events.reduce(Int64(0)) { $0 + $1.tokens.total } == 120, "unchanged upstream adapter reads configured directory")
        check(first.success && first.warnings.isEmpty, "irrelevant and malformed rows are skipped just as ccusage does, with no incomplete-scan banner")
        check(first.events.first?.apiCost != nil, "amount comes from the upstream pricing implementation")
        let restored = await TokenLogScanner(cacheURL: cache).restore(accounts: [a])
        check(restored.events == first.events && restored.lastSuccess == Date(timeIntervalSince1970: 100), "small daily summary is immediately available after restart")
        let bytes = try String(contentsOf: cache, encoding: .utf8)
        check(!bytes.contains("private_user_prompt") && !bytes.contains("requestId") && !bytes.contains("msg_1"), "cache stores daily/model summaries, never prompts or per-request traces")
        let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "summary cache is private")
        let duplicate = project.appendingPathComponent("copy.jsonl")
        try Data((line + "\n").utf8).write(to: duplicate)
        let copied = try await scanner.scan(accounts: [a], now: Date(timeIntervalSince1970: 200))
        check(copied.events.reduce(Int64(0)) { $0 + $1.tokens.total } == 120, "upstream deduplicates copied logs across files")
        let homeB = root.appendingPathComponent("claude-b")
        let projectB = homeB.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        let b = AccountID(provider: .claude, directory: homeB.path)
        let lineB = line.replacingOccurrences(of: "msg_1", with: "msg_2").replacingOccurrences(of: "\"requestId\":\"r\"", with: "\"requestId\":\"r2\"").replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":200")
        try Data((lineB + "\n").utf8).write(to: projectB.appendingPathComponent("two.jsonl"))
        let multiple = try await TokenLogScanner(cacheURL: root.appendingPathComponent("multi.json")).scan(accounts: [a, b], now: Date(timeIntervalSince1970: 1000))
        check(multiple.events.filter { $0.account == a }.reduce(Int64(0)) { $0 + $1.tokens.total } == 120, "first account retains only logs from its configured path")
        check(multiple.events.filter { $0.account == b }.reduce(Int64(0)) { $0 + $1.tokens.total } == 220, "second account keeps its path attribution instead of merging into first account")
        check(Set(multiple.events.map(\.id)).count == multiple.events.count, "daily model row identifiers include the account path")
        try FileManager.default.removeItem(at: homeB)
        let extra = lineB.replacingOccurrences(of: "msg_2", with: "msg_3").replacingOccurrences(of: "r2", with: "r3")
        try Data((extra + "\n").utf8).write(to: project.appendingPathComponent("extra.jsonl"))
        let mixed = try await TokenLogScanner(cacheURL: root.appendingPathComponent("multi.json")).scan(accounts: [a, b])
        check(!mixed.success && mixed.warnings.count == 1, "one inaccessible account does not prevent other accounts from being analyzed")
        check(mixed.events.filter { $0.account == a }.reduce(Int64(0)) { $0 + $1.tokens.total } == 340, "healthy account publishes new usage during a partial source failure")
        check(mixed.events.filter { $0.account == b } == multiple.events.filter { $0.account == b }, "failed account retains only its own prior summary")
        let mixedRestore = await TokenLogScanner(cacheURL: root.appendingPathComponent("multi.json")).restore(accounts: [a,b])
        check(mixedRestore.events == mixed.events && mixedRestore.lastSuccess == multiple.lastSuccess, "partial scan data and prior successful time survive restart")
        let damaged = root.appendingPathComponent("damaged.json")
        try Data("{truncated".utf8).write(to: damaged)
        let damagedScanner = TokenLogScanner(cacheURL: damaged)
        let damagedRestore = await damagedScanner.restore(accounts: [a])
        check(damagedRestore.events.isEmpty && damagedRestore.lastSuccess == nil, "truncated summary cache is ignored without inventing a successful scan")
        let recovered = try await damagedScanner.scan(accounts: [a])
        check(recovered.success && recovered.events.first?.tokens.total == 340, "normal scanning rebuilds a damaged cache from upstream results")
        let incompatible = root.appendingPathComponent("incompatible.json")
        try Data(bytes.replacingOccurrences(of: "20.0.44", with: "old-engine").utf8).write(to: incompatible)
        let incompatibleRestore = await TokenLogScanner(cacheURL: incompatible).restore(accounts: [a])
        check(incompatibleRestore.events.isEmpty, "summaries from a different engine version are never reused")
        let excluded = await scanner.restore(accounts: [])
        check(excluded.events.isEmpty, "unchecked sources never leak through the persisted summary")
        try FileManager.default.removeItem(at: home)
        let failed = try await scanner.scan(accounts: [a], now: Date(timeIntervalSince1970: 300))
        check(!failed.success && failed.events == copied.events && failed.lastSuccess == copied.lastSuccess, "real source failure retains prior data and successful time")
        var settings = UserSettings(accounts: [a], defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5)
        check(settings.tokenUsage.automatic && settings.tokenUsage.intervalMinutes == 30, "scan defaults remain thirty minutes")
        settings.tokenUsage.excludedAccounts = [a]
        check(settings.tokenUsage.sources(in: settings.accounts).isEmpty, "log source checkbox uses configured accounts")
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
        settings.tokenUsage.intervalMinutes = 45
        try await store.save(settings)
        let saved = try await store.loadOrSeed()
        check(saved.tokenUsage.intervalMinutes == 45 && saved.tokenUsage.excludedAccounts == [a], "scan settings persist independently")
        check(!saved.autoRefreshOnOpen && !saved.usageStatisticsEnabled && saved.samplingIntervalHours == 4, "existing quota settings keep their behavior")
    } catch { check(false, "upstream source adapter fixture: \(error)") }
}

private actor TokenOperationGate {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func run(_ accounts: [AccountID], now: Date) async throws -> TokenScanResult {
        calls += 1
        if calls == 1 { await withCheckedContinuation { continuation = $0 } }
        return TokenScanResult(lastSuccess: now)
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor func runTokenControllerChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = AccountID(provider: .claude, directory: root.path)
    let gate = TokenOperationGate()
    let controller = TokenUsageController(scanner: TokenLogScanner(cacheURL: root.appendingPathComponent("cache.json")), accounts: [account], operation: { sources, now in try await gate.run(sources, now: now) })
    let now = Date()
    let first = Task { await controller.scan(now: now) }
    for _ in 0..<100 { if await gate.calls > 0 { break }; await Task.yield() }
    await controller.scan(now: now)
    check(await gate.calls == 1, "concurrent manual scans coalesce rather than queue duplicate work")
    check(controller.isScanning, "scan remains busy for the entire asynchronous operation")
    check(controller.scanProgress?.accounts == [account] && controller.scanProgress?.completed.isEmpty == true, "scan progress exposes actual active tools while the operation is pending")
    await gate.release(); await first.value
    check(controller.lastSuccess == now, "successful scan advances central timestamp")
    check(controller.scanProgress == nil, "finished scans clear transient progress")
    check(controller.nextScan == now.addingTimeInterval(1800), "default next scan is thirty minutes after attempt")
    await controller.tick(now: now.addingTimeInterval(1799))
    check(await gate.calls == 1, "timer does not scan before due time")
    await controller.tick(now: now.addingTimeInterval(1800))
    check(await gate.calls == 2, "timer starts exactly one due scan")
    var settings = TokenUsageSettings(); settings.automatic = false
    controller.configure(settings: settings, accounts: [account], now: now)
    check(controller.nextScan == nil, "disabling automatic scanning clears next due time")
    await controller.tick(now: now.addingTimeInterval(9999))
    check(await gate.calls == 2, "manual-only mode never runs scheduled scans")
    await controller.scan(now: now)
    check(await gate.calls == 3, "manual scan still works with timer disabled")
    settings.excludedAccounts = [account]; controller.configure(settings: settings, accounts: [account])
    await controller.scan()
    check(await gate.calls == 3, "no selected directories means no file scan")
    let failing = TokenUsageController(scanner: TokenLogScanner(cacheURL: root.appendingPathComponent("fail.json")), accounts: [account], operation: { _, _ in throw CocoaError(.fileReadNoPermission) })
    await failing.scan(now: now)
    check(failing.lastSuccess == nil && !failing.warnings.isEmpty, "failed scan does not invent success time")
    let timerGate = TokenOperationGate()
    let timer = TokenUsageController(scanner: TokenLogScanner(cacheURL: root.appendingPathComponent("timer.json")), accounts: [account], operation: { sources, now in try await timerGate.run(sources, now: now) })
    let boot = Task { await timer.start(now: now) }
    for _ in 0..<200 { if await timerGate.calls > 0 { break }; try? await Task.sleep(for: .milliseconds(1)) }
    let other = AccountID(provider: .codex, directory: root.path)
    timer.configure(settings: TokenUsageSettings(), accounts: [other], now: now)
    timer.configure(settings: TokenUsageSettings(automatic: false), accounts: [other], now: now)
    await timerGate.release(); await boot.value
    check(await timerGate.calls == 1 && timer.nextScan == nil, "disabling auto scan cancels a configuration-triggered follow-up scan")
    controller.select(period: .today, now: now)
    check(!controller.selectCustom(start: now, end: now.addingTimeInterval(86400), now: now), "future custom dates are rejected without changing selection")
    check(controller.period == .today, "invalid custom range preserves applied period")
    check(controller.selectCustom(start: now.addingTimeInterval(-86400), end: now, now: now) && controller.period == .custom, "valid custom range applies immediately")
    await controller.waitForSummary()
    let raceGate = TokenOperationGate()
    let racing = TokenUsageController(scanner: TokenLogScanner(cacheURL: root.appendingPathComponent("race.json")), accounts: [account], operation: { sources, now in try await raceGate.run(sources, now: now) })
    let pending = Task { await racing.scan(now: now) }
    for _ in 0..<100 { if await raceGate.calls > 0 { break }; await Task.yield() }
    racing.configure(settings: settings, accounts: [account])
    await raceGate.release(); await pending.value
    check(racing.lastSuccess == nil && racing.events.isEmpty, "changing selected roots invalidates an in-flight result")
}

@MainActor func runTokenLiveChecks() async {
    let settingsURL = StorageSupport.appSupportURL("settings.json")
    guard FileManager.default.fileExists(atPath: settingsURL.path) else { check(false, "installed settings required for read-only log validation"); return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let settings = try await SettingsStore(url: settingsURL).loadOrSeed()
        let url = root.appendingPathComponent("cache.json")
        let scanner = TokenLogScanner(cacheURL: url)
        let start = Date()
        let result = try await scanner.scan(accounts: settings.tokenUsage.sources(in: settings.accounts))
        print("ccusage core: \(result.events.count) daily/model buckets; \(result.warnings.count) source errors; \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        let restoreStart = Date()
        let restored = await TokenLogScanner(cacheURL: url).restore(accounts: settings.tokenUsage.sources(in: settings.accounts))
        let bytes = try Data(contentsOf: url).count
        print("Restart restore: \(String(format: "%.4f", Date().timeIntervalSince(restoreStart))) s; cache \(bytes) bytes")
        check(!result.events.isEmpty && result.success, "real selected logs are analyzed by unmodified upstream core")
        check(result.events.allSatisfy { $0.tokens.total >= 0 }, "core-reported totals survive the display adapter")
        check(restored.events == result.events && bytes < 1_000_000, "daily summary restores without a per-request event dump")
        check(result.events.allSatisfy { settings.accounts.contains($0.account) && !settings.tokenUsage.excludedAccounts.contains($0.account) }, "only checked source directories contribute to display")
    } catch { check(false, "read-only upstream validation: \(error)") }
}

@MainActor func runTokenEdgeChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let project = root.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let account = AccountID(provider: .claude, directory: root.path)
        let lines = (0..<1000).map { i in
            #"{"type":"assistant","timestamp":"2026-10-26T01:00:00Z","sessionId":"s","requestId":"rINDEX","message":{"id":"msg_INDEX","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":20}}}"#.replacingOccurrences(of: "INDEX", with: String(i))
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: project.appendingPathComponent("bulk.jsonl"))
        let cache = root.appendingPathComponent("cache.json")
        let result = try await TokenLogScanner(cacheURL: cache).scan(accounts: [account])
        check(result.events.count == 1 && result.events[0].tokens.total == 120_000, "1000 real requests are aggregated by the upstream daily loader")
        check(try Data(contentsOf: cache).count < 16_384, "persistence scales with daily/model buckets rather than request count")
        let empty = try await TokenLogScanner(cacheURL: root.appendingPathComponent("empty.json")).scan(accounts: [])
        check(empty.events.isEmpty && empty.success, "no selected accounts means no engine process and no spurious warning")
    } catch { check(false, "upstream aggregation regression: \(error)") }
    var progress = TokenScanProgress(accounts: [AccountID(provider: .claude, directory: "/tmp/progress-a"), AccountID(provider: .claude, directory: "/tmp/progress-b"), AccountID(provider: .codex, directory: "/tmp/progress-c")], startedAt: Date())
    progress.apply(.completed(progress.accounts[2], succeeded: true))
    progress.apply(.completed(progress.accounts[2], succeeded: true))
    check(progress.completed == [progress.accounts[2]] && progress.label == "账号 1/3", "duplicate process notifications never inflate actual completion count")
    progress.apply(.completed(progress.accounts[0], succeeded: false))
    progress.apply(.completed(progress.accounts[1], succeeded: false))
    check(progress.completedAccounts == 3 && progress.failed == Set(progress.accounts.prefix(2)), "failed tools are distinguished from successful completion")
    progress.apply(.saving)
    check(progress.phase == .saving, "saving is a distinct stage rather than a fabricated percentage")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let spring = ISO8601DateFormatter().date(from: "2026-03-08T20:00:00Z")!
    let springRange = TokenDateRange.preset(.today, now: spring, calendar: cal)
    check(springRange.end.timeIntervalSince(springRange.start) == 23 * 3600, "date UI respects daylight-saving transitions")
}
