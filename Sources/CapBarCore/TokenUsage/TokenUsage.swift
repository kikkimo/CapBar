import Foundation

struct TokenCounts: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheRead: Int64 = 0
    var reportedTotal: Int64? = nil
    var total: Int64 { reportedTotal ?? (input + output + cacheWrite + cacheRead) }
    mutating func add(_ other: Self) {
        func sum(_ a: Int64, _ b: Int64) -> Int64 { let (n, overflow) = a.addingReportingOverflow(b); return overflow ? Int64.max / 8 : min(n, Int64.max / 8) }
        let combinedTotal = sum(total, other.total)
        input = sum(input, other.input); output = sum(output, other.output)
        cacheWrite = sum(cacheWrite, other.cacheWrite); cacheRead = sum(cacheRead, other.cacheRead)
        reportedTotal = combinedTotal
    }
}

/// A daily/model row already analyzed and priced by ccusage.
struct TokenUsageEvent: Codable, Equatable, Sendable {
    var id: String
    var account: AccountID
    var timestamp: Date
    var model: String
    var tokens: TokenCounts
    /// Already calculated by the unchanged ccusage core; Swift never reprices it.
    var apiCost: Double? = nil
    var missingPricing = false
}

enum TokenPeriod: String, CaseIterable, Sendable {
    case today, sevenDays, thirtyDays, custom
    var label: String { switch self { case .today: "今日"; case .sevenDays: "近 7 日"; case .thirtyDays: "近 30 日"; case .custom: "自定义" } }
}

struct TokenDateRange: Equatable, Sendable {
    var start: Date
    /// Exclusive local midnight after the last selected date.
    var end: Date
    static func preset(_ period: TokenPeriod, now: Date, calendar: Calendar) -> Self {
        let today = calendar.startOfDay(for: now)
        let days = period == .today ? 1 : period == .thirtyDays ? 30 : 7
        return Self(start: calendar.date(byAdding: .day, value: 1 - days, to: today)!, end: calendar.date(byAdding: .day, value: 1, to: today)!)
    }
    static func custom(start: Date, end: Date, calendar: Calendar) -> Self? {
        let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
        guard first <= last, let exclusive = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return Self(start: first, end: exclusive)
    }
    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

enum TokenScanFreshness: Sendable {
    case unknown, fresh, delayed, stale, manual
    static func classify(lastSuccess: Date?, now: Date, intervalMinutes: Int, automatic: Bool) -> Self {
        guard let lastSuccess else { return .unknown }
        guard automatic else { return .manual }
        let age = max(0, now.timeIntervalSince(lastSuccess)), interval = Double(intervalMinutes) * 60
        return age <= interval ? .fresh : age <= interval * 2 ? .delayed : .stale
    }
}

struct TokenUsageBucket: Identifiable, Sendable {
    var id: String
    var label: String
    var date: Date? = nil
    var provider: Provider? = nil
    var account: AccountID? = nil
    var tokens = TokenCounts()
    var knownCost = 0.0
    var pricedEvents = 0
    var unpricedEvents = 0
    var eventCount: Int { pricedEvents + unpricedEvents }
    mutating func add(_ event: TokenUsageEvent, cost: Double?) {
        tokens.add(event.tokens)
        if let cost { knownCost += cost }
        if cost != nil && !event.missingPricing { pricedEvents += 1 } else { unpricedEvents += 1 }
    }
}

enum TokenReportGrouping: String, CaseIterable { case day, month, model, provider, account
    var label: String { switch self { case .day: "按日"; case .month: "按月"; case .model: "按模型"; case .provider: "按工具"; case .account: "按账号" } }
}

struct TokenUsageSummary: Sendable {
    var total = TokenUsageBucket(id: "total", label: "合计")
    var daily: [TokenUsageBucket] = []
    var monthly: [TokenUsageBucket] = []
    var dailyByProvider: [TokenUsageBucket] = []
    var dailyByAccount: [TokenUsageBucket] = []
    var dailyByModel: [TokenUsageBucket] = []
    var accounts: [TokenUsageBucket] = []
    var models: [TokenUsageBucket] = []
    var providers: [TokenUsageBucket] = []
    var tokens: TokenCounts { total.tokens }
    func rows(for grouping: TokenReportGrouping) -> [TokenUsageBucket] {
        switch grouping { case .day: daily.reversed(); case .month: monthly.reversed(); case .model: models; case .provider: providers; case .account: accounts }
    }
    static func build(events: [TokenUsageEvent], range: TokenDateRange, provider: Provider?, calendar: Calendar, account: AccountID? = nil) -> Self {
        var result = Self(), days: [Date: TokenUsageBucket] = [:], months: [Date: TokenUsageBucket] = [:]
        var dailyTools: [String: TokenUsageBucket] = [:]
        var dailyAccounts: [String: TokenUsageBucket] = [:], dailyModels: [String: TokenUsageBucket] = [:], accounts: [String: TokenUsageBucket] = [:]
        var models: [String: TokenUsageBucket] = [:], providers: [String: TokenUsageBucket] = [:]
        let dayFormatter = DateFormatter(); dayFormatter.calendar = calendar; dayFormatter.timeZone = calendar.timeZone; dayFormatter.dateFormat = "MM/dd"
        let monthFormatter = DateFormatter(); monthFormatter.calendar = calendar; monthFormatter.timeZone = calendar.timeZone; monthFormatter.dateFormat = "yyyy-MM"
        for event in events where range.contains(event.timestamp) && (provider == nil || event.account.provider == provider) && (account == nil || event.account == account) {
            if Task.isCancelled { break }
            let cost = event.apiCost, day = calendar.startOfDay(for: event.timestamp)
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
            result.total.add(event, cost: cost)
            var d = days[day] ?? TokenUsageBucket(id: String(day.timeIntervalSince1970), label: dayFormatter.string(from: day), date: day)
            d.add(event, cost: cost); days[day] = d
            let dayTool = "\(day.timeIntervalSince1970):\(event.account.provider.rawValue)"
            var dt = dailyTools[dayTool] ?? TokenUsageBucket(id: dayTool, label: d.label, date: day, provider: event.account.provider)
            dt.add(event, cost: cost); dailyTools[dayTool] = dt
            var m = months[month] ?? TokenUsageBucket(id: String(month.timeIntervalSince1970), label: monthFormatter.string(from: month), date: month)
            m.add(event, cost: cost); months[month] = m
            let modelKey = event.account.provider.rawValue + ":" + event.model
            var model = models[modelKey] ?? TokenUsageBucket(id: modelKey, label: event.model, provider: event.account.provider)
            model.add(event, cost: cost); models[modelKey] = model
            let accountKey = event.account.provider.rawValue + ":" + event.account.directory
            var a = accounts[accountKey] ?? TokenUsageBucket(id: accountKey, label: event.account.directory, provider: event.account.provider, account: event.account)
            a.add(event, cost: cost); accounts[accountKey] = a
            let dailyAccountKey = "\(day.timeIntervalSince1970):\(accountKey)"
            var da = dailyAccounts[dailyAccountKey] ?? TokenUsageBucket(id: dailyAccountKey, label: event.account.directory, date: day, provider: event.account.provider, account: event.account)
            da.add(event, cost: cost); dailyAccounts[dailyAccountKey] = da
            let dailyModelKey = "\(day.timeIntervalSince1970):\(modelKey)"
            var dm = dailyModels[dailyModelKey] ?? TokenUsageBucket(id: dailyModelKey, label: event.model, date: day, provider: event.account.provider)
            dm.add(event, cost: cost); dailyModels[dailyModelKey] = dm
            let p = event.account.provider.rawValue
            var tool = providers[p] ?? TokenUsageBucket(id: p, label: event.account.provider == .claude ? "Claude Code" : "Codex", provider: event.account.provider)
            tool.add(event, cost: cost); providers[p] = tool
        }
        result.daily = days.values.sorted { $0.date! < $1.date! }
        result.dailyByProvider = dailyTools.values.sorted { $0.id < $1.id }
        result.accounts = accounts.values.sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total }
        result.dailyByAccount = dailyAccounts.values.sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total }
        result.dailyByModel = dailyModels.values.sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total }
        result.monthly = months.values.sorted { $0.date! < $1.date! }
        result.models = models.values.sorted { $0.knownCost == $1.knownCost ? $0.tokens.total > $1.tokens.total : $0.knownCost > $1.knownCost }
        result.providers = providers.values.sorted { $0.id < $1.id }
        return result
    }
}
