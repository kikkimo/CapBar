import AppKit
import Charts
import SwiftUI

enum TokenDisplay {
    static func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
    static func millions(_ value: Int64) -> String {
        if value > 0 && value < 10_000 { return "<0.01M" }
        return (Double(value) / 1_000_000).formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2))) + "M"
    }
    static func money(_ bucket: TokenUsageBucket) -> String {
        guard bucket.eventCount > 0, bucket.pricedEvents > 0 || bucket.knownCost > 0 else { return "—" }
        return bucket.knownCost.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))) + (bucket.unpricedEvents > 0 ? " +" : "")
    }
    static func provider(_ value: Provider?) -> String { value == .claude ? "Claude Code" : value == .codex ? "Codex" : "全部工具" }
    static func nextScan(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: date)
    }
    static func dateRange(_ range: TokenDateRange) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
        return f.string(from: range.start) + "–" + f.string(from: range.end.addingTimeInterval(-1)) + " · 本地时间"
    }
}

struct TokenScanStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: TokenUsageController
    private let secondary = Color(nsColor: .secondaryLabelColor)
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let freshness = TokenScanFreshness.classify(lastSuccess: controller.lastSuccess, now: timeline.date, intervalMinutes: controller.settings.intervalMinutes, automatic: controller.settings.automatic)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { policy; Spacer(minLength: 0); times(now: timeline.date, freshness: freshness) }
                VStack(alignment: .leading, spacing: 5) { policy; HStack { Spacer(); times(now: timeline.date, freshness: freshness) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .overlay(alignment: .bottom) { Color(nsColor: .separatorColor).frame(height: 1) }
        }
    }
    private var policy: some View {
        Text(controller.settings.automatic ? "每 \(controller.settings.intervalMinutes) 分钟自动扫描" : "仅手动扫描")
            .font(.system(size: 9)).foregroundStyle(secondary).fixedSize()
    }
    private func times(now: Date, freshness: TokenScanFreshness) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("上次").foregroundStyle(secondary)
                Label(lastLabel(now: now, freshness: freshness), systemImage: "clock")
                    .foregroundStyle(color(freshness == .fresh && !controller.warnings.isEmpty ? .delayed : freshness))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color(freshness == .fresh && !controller.warnings.isEmpty ? .delayed : freshness).opacity(0.12), in: Capsule())
                    .help(controller.lastSuccess.map { "最近完成扫描：\($0.formatted(date: .abbreviated, time: .standard))" } ?? "尚未完成扫描")
                    .accessibilityLabel("上次扫描：\(lastLabel(now: now, freshness: freshness))")
            }
            HStack(spacing: 4) {
                Text("下次").foregroundStyle(secondary)
                Label(controller.isScanning ? "扫描中" : controller.nextScan.map { TokenDisplay.nextScan($0, now: now) } ?? (controller.settings.automatic ? "待安排" : "已关闭"), systemImage: "clock")
                    .foregroundStyle(controller.settings.automatic ? Color.accentColor : secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background((controller.settings.automatic ? Color.accentColor : secondary).opacity(0.12), in: Capsule())
            }
        }
        .font(.system(size: 10, weight: .semibold)).monospacedDigit().fixedSize()
    }
    private func lastLabel(now: Date, freshness: TokenScanFreshness) -> String {
        guard let date = controller.lastSuccess else { return "尚未扫描" }
        let text = capturedAtLabel(date, now: now, calendar: .current)
        return text + (freshness == .delayed ? " · 已延迟" : freshness == .stale ? " · 已过期" : "")
    }
    private func color(_ freshness: TokenScanFreshness) -> Color {
        switch freshness {
        case .fresh: colorScheme == .dark ? Color(red: 0.45, green: 0.80, blue: 0.57) : Color(red: 0.15, green: 0.43, blue: 0.25)
        case .delayed: colorScheme == .dark ? Color(red: 1, green: 0.73, blue: 0.34) : Color(red: 0.60, green: 0.35, blue: 0.04)
        case .stale: colorScheme == .dark ? Color(red: 1, green: 0.49, blue: 0.46) : Color(red: 0.71, green: 0.18, blue: 0.17)
        case .unknown, .manual: secondary
        }
    }
}

enum TokenProviderStyle {
    static func color(_ provider: Provider?, scheme: ColorScheme) -> Color {
        if provider == .claude {
            return scheme == .dark ? Color(red: 0.83, green: 0.59, blue: 0.44) : Color(red: 0.75, green: 0.46, blue: 0.34)
        }
        return scheme == .dark ? Color(red: 0.42, green: 0.65, blue: 0.75) : Color(red: 0.29, green: 0.48, blue: 0.59)
    }
}

struct CapBarTokenUsageView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: TokenUsageController
    let openSettings: () -> Void
    let openReport: () -> Void
    let accountLabels: [AccountID: String]
    @State private var editsRange = false
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var rangeError = false
    @State private var showsCost = false
    @State private var summaryGrouping: TokenReportGrouping = .account
    @State private var hoveredDay: Date?
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let line = Color(nsColor: .separatorColor)
    private var claude: Color { TokenProviderStyle.color(.claude, scheme: colorScheme) }
    private var codex: Color { TokenProviderStyle.color(.codex, scheme: colorScheme) }
    init(controller: TokenUsageController, accountLabels: [AccountID: String] = [:], openReport: @escaping () -> Void = {}, initiallyHoveredDay: Date? = nil, initialSummaryGrouping: TokenReportGrouping = .account, openSettings: @escaping () -> Void) {
        self.controller = controller; self.openSettings = openSettings; self.openReport = openReport; self.accountLabels = accountLabels
        self._hoveredDay = State(initialValue: initiallyHoveredDay)
        self._summaryGrouping = State(initialValue: initialSummaryGrouping)
    }
    var body: some View {
        VStack(spacing: 0) {
            TokenScanStatusView(controller: controller)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    filters
                    accountFilter
                    if editsRange { customRange }
                    Text(TokenDisplay.dateRange(controller.range)).font(.system(size: 10)).foregroundStyle(secondary).padding(.horizontal, 16)
                    if !controller.warnings.isEmpty { warning }
                    if controller.sources.isEmpty { empty("尚未勾选日志来源", detail: "在账号与设置的「用量」中勾选已配置的账号目录。") }
                    else if controller.summary.total.eventCount == 0 { empty(controller.isScanning || controller.isSummarizing ? "正在分析本机日志" : "所选时段暂无用量记录", detail: "仅统计所选账号目录中保留的日志；可调整时段或手动扫描。") }
                    else { metrics; chart; providers }
                }
            }
            HStack {
                Text("本机日志 · 已勾选 \(controller.sources.count) 个来源").font(.system(size: 10)).foregroundStyle(secondary)
                Spacer()
                Button("详细报表 ↗", action: openReport).font(.system(size: 11))
            }
            .padding(.horizontal, 16).padding(.vertical, 10).overlay(alignment: .top) { line.frame(height: 1) }
        }
    }
    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(TokenPeriod.allCases, id: \.self) { period in
                    Button(period.label) {
                        if period == .custom { editsRange.toggle(); start = controller.range.start; end = controller.range.end.addingTimeInterval(-1); rangeError = false }
                        else { editsRange = false; controller.select(period: period) }
                    }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background((editsRange ? period == .custom : controller.period == period) ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityAddTraits((editsRange ? period == .custom : controller.period == period) ? .isSelected : [])
                }
            }
            .padding(2).background(Color(nsColor: .separatorColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            Spacer(minLength: 0)
            Picker("工具", selection: Binding(get: { controller.provider }, set: { controller.select(provider: $0) })) {
                Text("全部工具").tag(Optional<Provider>.none)
                Text("Claude Code").tag(Optional(Provider.claude))
                Text("Codex").tag(Optional(Provider.codex))
            }.labelsHidden().font(.system(size: 10)).frame(width: 110).controlSize(.small)
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
    private func accountLabel(_ account: AccountID) -> String {
        accountLabels[account] ?? abbreviated(account.directory)
    }
    private var accountFilter: some View {
        HStack(spacing: 8) {
            Text("账号").font(.system(size: 10)).foregroundStyle(secondary)
            Picker("账号", selection: Binding(get: { controller.account }, set: { controller.select(account: $0) })) {
                Text("全部账号").tag(Optional<AccountID>.none)
                ForEach(controller.sources.filter { controller.provider == nil || $0.provider == controller.provider }, id: \.self) { account in
                    Text(accountLabel(account)).tag(Optional(account))
                }
            }.labelsHidden().controlSize(.small).font(.system(size: 10))
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.bottom, 8)
    }
    private var customRange: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                DatePicker("开始", selection: $start, in: ...Date(), displayedComponents: .date)
                DatePicker("结束", selection: $end, in: ...Date(), displayedComponents: .date)
            }.font(.system(size: 10)).datePickerStyle(.field).controlSize(.small)
            HStack {
                Text("含起止两日 · 本地时间").foregroundStyle(secondary)
                Spacer()
                Button("取消") { editsRange = false; rangeError = false }
                Button("应用") { if controller.selectCustom(start: start, end: end) { editsRange = false; rangeError = false } else { rangeError = true } }.buttonStyle(.borderedProminent)
            }.font(.system(size: 10)).controlSize(.small)
            if rangeError { Text("开始日期不能晚于结束日期，结束日期不能晚于今天").font(.system(size: 10)).foregroundStyle(.red) }
        }
        .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 16).padding(.bottom, 10)
    }
    private var metrics: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("总 token").font(.system(size: 11)).foregroundStyle(secondary)
                    Text(TokenDisplay.compact(controller.summary.tokens.total)).font(.system(size: 27, weight: .bold)).monospacedDigit()
                    Text("包含缓存读写").font(.system(size: 10)).foregroundStyle(secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                line.frame(width: 1, height: 65)
                VStack(alignment: .leading, spacing: 3) {
                    Text("API 等价金额 · USD").font(.system(size: 11)).foregroundStyle(secondary)
                    Text(TokenDisplay.money(controller.summary.total)).font(.system(size: 26, weight: .bold)).foregroundStyle(Color.accentColor).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                    Text(controller.summary.total.unpricedEvents > 0 ? "另有未定价用量" : "按模型与 token 类型估算").font(.system(size: 9)).foregroundStyle(secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("API 等价估算 · 不代表实际账单或订阅扣费").font(.system(size: 10)).foregroundStyle(secondary)
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }
    private var chart: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("每日用量").font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("图表指标", selection: $showsCost) { Text("Token").tag(false); Text("金额").tag(true) }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 115)
            }
            HStack(spacing: 12) {
                Label { Text("Claude Code") } icon: { Circle().fill(claude).frame(width: 6, height: 6) }
                Label { Text("Codex") } icon: { Circle().fill(codex).frame(width: 6, height: 6) }
            }.font(.system(size: 9)).foregroundStyle(secondary)
            Chart {
                ForEach(controller.summary.dailyByProvider) { bucket in
                if let date = bucket.date, !showsCost || bucket.pricedEvents > 0 || bucket.knownCost > 0 {
                    BarMark(x: .value("日期", date, unit: .day), y: .value(showsCost ? "USD" : "Token", showsCost ? bucket.knownCost : Double(bucket.tokens.total)))
                        .foregroundStyle(by: .value("工具", TokenDisplay.provider(bucket.provider)))
                        .accessibilityLabel("\(bucket.label) \(TokenDisplay.provider(bucket.provider))")
                        .accessibilityValue(showsCost ? TokenDisplay.money(bucket) : "\(bucket.tokens.total) token")
                }
                }
                if let day = hoveredDay {
                    RuleMark(x: .value("悬浮日期", Calendar.current.date(byAdding: .hour, value: 12, to: day) ?? day))
                        .foregroundStyle(secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(domain: ["Claude Code", "Codex"], range: [claude, codex])
            .chartLegend(.hidden).chartXScale(domain: controller.range.start...controller.range.end)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(showsCost ? String(format: "$%.0f", number) : TokenDisplay.compact(Int64(max(0, min(number, Double(Int64.max / 8)))))).font(.system(size: 9)) } }
            }}
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let anchor = proxy.plotFrame else { hoveredDay = nil; return }
                                let frame = geometry[anchor]
                                guard frame.contains(location), let value: Date = proxy.value(atX: location.x - frame.minX), controller.range.contains(value) else { return }
                                hoveredDay = Calendar.current.startOfDay(for: value)
                            case .ended: break
                            }
                        }

                }
            }
            .frame(height: 125)
            Text(showsCost ? "金额仅含已定价部分 · 按日累计" : "按日累计 · 包含今日已记录用量").font(.system(size: 9)).foregroundStyle(secondary)
            if let day = hoveredDay {
                TokenUsageTooltip(date: day, buckets: controller.summary.dailyByProvider.filter { $0.date == day }, accounts: controller.summary.dailyByAccount.filter { $0.date == day }, accountLabels: accountLabels)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).overlay(alignment: .top) { line.frame(height: 1) }
        .onHover { inside in if !inside { hoveredDay = nil } }
    }
    private var summaryRows: [TokenUsageBucket] {
        switch summaryGrouping {
        case .account: controller.summary.accounts
        case .model: controller.summary.models
        default: controller.summary.providers
        }
    }
    private var providers: some View {
        VStack(spacing: 0) {
            HStack {
                Text("用量构成").font(.system(size: 10, weight: .semibold))
                Spacer()
                Picker("汇总分组", selection: $summaryGrouping) {
                    Text("工具").tag(TokenReportGrouping.provider)
                    Text("账号").tag(TokenReportGrouping.account)
                    Text("模型").tag(TokenReportGrouping.model)
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 165)
            }.padding(.horizontal, 16).padding(.vertical, 6).background(Color(nsColor: .controlBackgroundColor))
            ForEach(summaryRows) { bucket in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Circle().fill(bucket.provider == .claude ? claude : codex).frame(width: 7, height: 7)
                        Text(bucket.account.map(accountLabel) ?? bucket.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(TokenDisplay.compact(bucket.tokens.total)).font(.system(size: 13, weight: .semibold))
                        Text(TokenDisplay.money(bucket)).font(.system(size: 11)).foregroundStyle(Color.accentColor).frame(minWidth: 60, alignment: .trailing)
                    }.monospacedDigit()
                    breakdown(bucket.tokens)
                    if let account = bucket.account {
                        Text(TokenDisplay.provider(account.provider) + " · " + abbreviated(account.directory)).font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1).truncationMode(.middle).help(account.directory)
                    } else if summaryGrouping == .model {
                        Text(TokenDisplay.provider(bucket.provider)).font(.system(size: 9)).foregroundStyle(secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).overlay(alignment: .bottom) { line.frame(height: 1) }
            }
        }
    }
    private func breakdown(_ tokens: TokenCounts) -> some View {
        HStack(spacing: 8) {
            tokenValue("非缓存输入", tokens.input); tokenValue("输出", tokens.output)
            tokenValue("缓存写入", tokens.cacheWrite); tokenValue("缓存读取", tokens.cacheRead)
        }
    }
    private func tokenValue(_ label: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9)).foregroundStyle(secondary); Text(TokenDisplay.compact(value)).font(.system(size: 11, weight: .medium)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 28)).foregroundStyle(secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
            Button("账号与设置", action: openSettings).font(.system(size: 11))
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }
    private var warning: some View {
        DisclosureGroup {
            ForEach(Array(controller.warnings.prefix(30).enumerated()), id: \.offset) { _, text in Text(text).font(.system(size: 9)).textSelection(.enabled) }
        } label: { Label("部分来源读取失败 · 保留上次结果", systemImage: "exclamationmark.triangle").font(.system(size: 10)) }
        .foregroundStyle(Color(nsColor: .systemOrange)).padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func abbreviated(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~", options: .anchored) }
}

/// Uses the same material, border, shadow and typography as the individual
/// quota-trend tooltip. Values are the core's daily buckets, not recomputation.
struct TokenUsageTooltip: View {
    @Environment(\.colorScheme) private var colorScheme
    let date: Date
    let buckets: [TokenUsageBucket]
    var accounts: [TokenUsageBucket] = []
    var accountLabels: [AccountID: String] = [:]
    private let secondary = Color(nsColor: .secondaryLabelColor)
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(date.formatted(.dateTime.year().month().day()) + " · 本地时间")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(secondary)
            if buckets.isEmpty { Text("当日暂无用量记录").foregroundStyle(secondary) }
            ForEach(buckets) { bucket in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(TokenProviderStyle.color(bucket.provider, scheme: colorScheme)).frame(width: 5, height: 5)
                        Text(TokenDisplay.provider(bucket.provider)).fontWeight(.semibold)
                        Spacer(minLength: 4)
                        Text(TokenDisplay.millions(bucket.tokens.total) + " token").fontWeight(.medium)
                        Text(TokenDisplay.money(bucket)).foregroundStyle(Color.accentColor).fontWeight(.bold)
                    }
                    HStack(spacing: 8) {
                        tooltipValue("非缓存输入", bucket.tokens.input); tooltipValue("输出", bucket.tokens.output)
                        tooltipValue("缓存写入", bucket.tokens.cacheWrite); tooltipValue("缓存读取", bucket.tokens.cacheRead)
                    }
                }
            }
            if buckets.count > 1 {
                Divider()
                HStack {
                    Text("当日合计").foregroundStyle(secondary); Spacer()
                    Text(TokenDisplay.millions(total.tokens.total)).fontWeight(.bold)
                    Text(TokenDisplay.money(total)).foregroundStyle(Color.accentColor).fontWeight(.bold)
                }
            }
            if !accounts.isEmpty {
                Divider()
                HStack { Text("账号贡献").fontWeight(.semibold); Spacer(); Text("Token · API 等价 USD").foregroundStyle(secondary) }
                ForEach(accounts) { bucket in
                    HStack(spacing: 6) {
                        Circle().fill(TokenProviderStyle.color(bucket.provider, scheme: colorScheme)).frame(width: 5, height: 5)
                        Text(bucket.account.flatMap { accountLabels[$0] } ?? (bucket.label as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule().fill(TokenProviderStyle.color(bucket.provider, scheme: colorScheme).opacity(0.15))
                            Capsule().fill(TokenProviderStyle.color(bucket.provider, scheme: colorScheme))
                                .frame(width: geometry.size.width * (total.tokens.total > 0 ? Double(bucket.tokens.total) / Double(total.tokens.total) : 0))
                        }.frame(width: 44, height: 5)
                        Text(TokenDisplay.millions(bucket.tokens.total)).fontWeight(.medium).frame(width: 46, alignment: .trailing)
                        Text(TokenDisplay.money(bucket)).foregroundStyle(Color.accentColor).frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
        .font(.system(size: 10)).monospacedDigit()
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
    }
    private var total: TokenUsageBucket {
        var result = TokenUsageBucket(id: "hover-total", label: "当日合计")
        for bucket in buckets {
            result.tokens.add(bucket.tokens); result.knownCost += bucket.knownCost
            result.pricedEvents += bucket.pricedEvents; result.unpricedEvents += bucket.unpricedEvents
        }
        return result
    }
    private func tooltipValue(_ name: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 9)).foregroundStyle(secondary)
            Text(count.formatted()).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
