import Foundation

enum TokenReportScope: String, CaseIterable, Sendable {
    case detail, day, month, account, model, provider
    var label: String { switch self {
    case .detail: "逐日明细"; case .day: "按日"; case .month: "按月"
    case .account: "按账号"; case .model: "按模型"; case .provider: "按工具"
    } }
    var grouping: TokenReportGrouping? { switch self {
    case .detail: nil; case .day: .day; case .month: .month
    case .account: .account; case .model: .model; case .provider: .provider
    } }
    var columnTitle: String { switch self { case .account: "账号"; case .model: "模型"; case .provider: "工具"; default: "日期" } }
}

struct TokenReportQuery: Sendable {
    var period: TokenPeriod
    var start: Date
    var end: Date
    var provider: Provider?
    var account: AccountID?
    var scope: TokenReportScope = .detail
    var search = ""
    init(range: TokenDateRange, period: TokenPeriod = .sevenDays, provider: Provider? = nil, account: AccountID? = nil) {
        self.period = period; start = range.start; end = range.end.addingTimeInterval(-1)
        self.provider = provider; self.account = account
    }
    func range(calendar: Calendar) -> TokenDateRange? { .custom(start: start, end: end, calendar: calendar) }
    mutating func select(_ period: TokenPeriod, now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        guard period != .custom else { return }
        let range = TokenDateRange.preset(period, now: now, calendar: calendar)
        start = range.start; end = range.end.addingTimeInterval(-1)
    }
}

struct TokenReportRow: Identifiable, Sendable {
    var bucket: TokenUsageBucket
    var primary: String
    var account: String
    var tool: String
    var model: String
    var id: String { bucket.id }
    var input: Int64 { bucket.tokens.input }
    var output: Int64 { bucket.tokens.output }
    var cacheWrite: Int64 { bucket.tokens.cacheWrite }
    var cacheRead: Int64 { bucket.tokens.cacheRead }
    var total: Int64 { bucket.tokens.total }
    var cost: Double { bucket.knownCost }
}

struct TokenReportResult: Sendable {
    var rows: [TokenReportRow] = []
    var total = TokenUsageBucket(id: "report-total", label: "筛选合计")
    var accountCount = 0
    var modelCount = 0
    static func build(events: [TokenUsageEvent], sources: [AccountID], labels: [AccountID: String], query: TokenReportQuery, calendar: Calendar = .current) -> Self {
        guard let range = query.range(calendar: calendar) else { return Self() }
        let allowed = Set(sources)
        let date = DateFormatter(); date.calendar = calendar; date.timeZone = calendar.timeZone
        date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd"
        let words = query.search.split(whereSeparator: { $0.isWhitespace }).map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        let selected = events.filter { event in
            guard allowed.contains(event.account), range.contains(event.timestamp), query.provider == nil || event.account.provider == query.provider, query.account == nil || event.account == query.account else { return false }
            let text = [labels[event.account] ?? "", event.account.directory, event.account.provider.rawValue, event.account.provider == .claude ? "Claude Code" : "Codex", event.model, date.string(from: event.timestamp)].joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { text.contains($0) }
        }
        let summary = TokenUsageSummary.build(events: selected, range: range, provider: nil, calendar: calendar)
        var result = Self(total: summary.total, accountCount: Set(selected.map(\.account)).count, modelCount: Set(selected.map { $0.account.provider.rawValue + ":" + $0.model }).count)
        if let grouping = query.scope.grouping {
            result.rows = summary.rows(for: grouping).map { bucket in
                let label = bucket.account.flatMap { labels[$0] } ?? bucket.label
                let primary = query.scope == .day ? bucket.date.map { date.string(from: $0) } ?? label : label
                return TokenReportRow(bucket: bucket, primary: primary, account: "—", tool: bucket.provider.map { $0 == .claude ? "Claude Code" : "Codex" } ?? "全部工具", model: "—")
            }
        } else {
            result.rows = selected.map { event in
                var bucket = TokenUsageBucket(id: event.id, label: date.string(from: event.timestamp), date: event.timestamp, provider: event.account.provider, account: event.account)
                bucket.add(event, cost: event.apiCost)
                return TokenReportRow(bucket: bucket, primary: bucket.label, account: labels[event.account] ?? (event.account.directory as NSString).abbreviatingWithTildeInPath, tool: event.account.provider == .claude ? "Claude Code" : "Codex", model: event.model)
            }
        }
        result.rows.sort { $0.id < $1.id }
        return result
    }
}
