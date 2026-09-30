import AppKit
import SwiftUI

struct CapBarPopoverView: View {
    @ObservedObject var model: CapBarViewModel

    private let line = Color(nsColor: .separatorColor)
    private let secondary = Color(nsColor: .secondaryLabelColor)

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.showsSettings {
                CapBarSettingsView(model: model)
            } else {
                overview
            }
            footer
        }
        .frame(width: CGFloat(model.settings.popoverSize.width), height: CGFloat(model.settings.popoverSize.height))
        .background {
            Rectangle().fill(.regularMaterial)
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.78))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("C")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .frame(width: 28, height: 28)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(line))
            VStack(alignment: .leading, spacing: 2) {
                Text("CapBar").font(.system(size: 13, weight: .semibold))
                Text("\(model.rows.count) 个账号 · \(model.settings.usageStatisticsEnabled ? "用量统计已开启" : model.settings.autoRefreshOnOpen ? "打开时按需刷新" : "仅手动刷新")")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.refreshAll()
            } label: {
                Label("全部刷新", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(line))
            }
            .buttonStyle(.plain)
            .help("刷新所有空闲账号；正在刷新的账号会跳过")
            Button {
                model.showsSettings = true
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .help("添加账号目录")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.58))
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            if model.showsTrend && model.settings.usageStatisticsEnabled {
                trendScopeBar
            }
            ScrollView {
                VStack(spacing: 0) {
                    if !model.rows.isEmpty && model.rows.allSatisfy({ $0.windows.isEmpty && !$0.isRefreshing && $0.error == nil }) {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.clockwise.circle")
                            Text("尚未采集额度，点击右上角“全部刷新”")
                            Spacer()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    }
                    if model.rows.isEmpty {
                        Text("尚未添加账号目录")
                            .font(.system(size: 12)).foregroundStyle(secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    providerGroup(.claude, title: "CLAUDE CODE", dot: Color(red: 0.77, green: 0.49, blue: 0.35))
                    providerGroup(.codex, title: "CODEX", dot: Color(red: 0.33, green: 0.66, blue: 0.52))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trendScopeBar: some View {
        HStack(spacing: 10) {
            Picker("走势图范围", selection: Binding(
                get: { model.trendScope },
                set: { model.setTrendScope($0) }
            )) {
                Text("单账号").tag(TrendScope.individual)
                Text("总走势").tag(TrendScope.total)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 153)
            Spacer(minLength: 0)
            Text("近 7 日 · \(max(2, model.settings.samplingIntervalHours)) 小时/点")
                .font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.68))
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    @ViewBuilder private func providerGroup(_ provider: Provider, title: String, dot: Color) -> some View {
        let rows = model.rows.filter { $0.account.provider == provider }
        if !rows.isEmpty {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.system(size: 10, weight: .bold)).tracking(0.6)
                Spacer()
                Text("\(rows.count) 个账号").font(.system(size: 10)).foregroundStyle(secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .overlay(alignment: .bottom) { line.frame(height: 1) }
            if model.showsTrend && model.trendScope == .total {
                CapBarTotalTrendCard(overview: model.trendOverview(for: provider),
                                     historical: model.historicalStatistics[provider], provider: provider) {
                    model.showsSettings = true
                }
                .padding(.horizontal, 16)
            } else {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    let tinted = !model.showsTrend && row.isExhausted
                    CapBarAccountRow(
                        row: row, width: model.settings.popoverSize.width,
                        statisticsEnabled: model.settings.usageStatisticsEnabled,
                        showsTrend: model.showsTrend,
                        trend: model.trends[row.account]
                    ) { model.refresh(row.account) }
                        .padding(.horizontal, 16)
                        .background {
                            if tinted {
                                LinearGradient(
                                    colors: [Color(nsColor: .systemRed).opacity(0.14),
                                             Color(nsColor: .systemRed).opacity(0.06)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            }
                        }
                    if index < rows.count - 1 && !tinted && (model.showsTrend || !rows[index + 1].isExhausted) {
                        line.frame(height: 1).padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.settings.usageStatisticsEnabled && !model.showsSettings {
                Picker("显示内容", selection: Binding(
                    get: { model.showsTrend },
                    set: { model.setTrendMode($0) }
                )) {
                    Text("额度").tag(false)
                    Text("走势").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)
                .controlSize(.small)
            } else {
                Text("额度为剩余百分比 · 时间为本地时间")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer()
            Button(model.showsSettings ? "返回总览" : "账号与设置") {
                model.showsSettings.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            if !model.showsSettings {
                line.frame(width: 1, height: 12).padding(.horizontal, 5)
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondary)
                    .accessibilityLabel("退出 CapBar")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.58))
        .overlay(alignment: .top) { line.frame(height: 1) }
    }
}

private struct CapBarTotalTrendCard: View {
    let overview: ProviderTrendOverview
    let historical: HistoricalTrendStatistics?
    let provider: Provider
    let openSettings: () -> Void

    private var title: String { provider == .claude ? "Claude 用量合计" : "Codex 用量合计" }
    private var latestUsage: Double? { overview.series?.points.last?.usedPercent }
    private var statistics: ProviderTrendStatistics? { overview.statistics(calendar: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("\(overview.accountCount) 个账号 · \(overview.baselinePlan.map { "以首账号 \($0.displayName) 为基准" } ?? "套餐待校准")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if overview.series != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(latestUsage.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                            .font(.system(size: 16, weight: .bold)).monospacedDigit()
                            .foregroundStyle(latestUsage == nil ? Color.secondary : Color.primary)
                        Text(latestUsage == nil ? "最近区间缺测" : "最近完整区间 · 估算")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            if overview.uncalibratedCount > 0 {
                HStack {
                    Text("\(overview.uncalibratedCount) 个账号套餐待校准，暂不计算总走势")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("去设置") { openSettings() }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 128)
            } else if overview.pendingHistoryCount > 0 {
                Text("\(overview.pendingHistoryCount) 个账号的历史数据暂不可用")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 128)
            } else {
                UsageTrendChart(
                    series: overview.series,
                    colorRange: overview.series.flatMap { UsageTrendColorScale.range(for: [$0]) },
                    totalOverview: overview
                )
            }
            if let statistics, statistics.validBinCount > 0, let binHours = overview.series?.binHours {
                CapBarTotalTrendStatistics(statistics: statistics, binHours: binHours)
            } else {
                Text("套餐容量按估算系数换算 · 缺测区间留空")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if overview.uncalibratedCount == 0 {
                CapBarHistoricalTrendStatistics(statistics: historical)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CapBarHistoricalTrendStatistics: View {
    let statistics: HistoricalTrendStatistics?

    @Environment(\.colorScheme) private var colorScheme
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let separator = Color(nsColor: .separatorColor)
    private var usageColor: Color {
        colorScheme == .dark ? Color(red: 0.51, green: 0.73, blue: 1.0)
                             : Color(red: 0.14, green: 0.47, blue: 0.82)
    }
    private var lowColor: Color {
        colorScheme == .dark ? Color(red: 0.43, green: 0.82, blue: 0.75)
                             : Color(red: 0.10, green: 0.55, blue: 0.49)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("历史纪录").font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("完整窗口 · 本地日期").font(.system(size: 9)).foregroundStyle(secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                record("历史最高 · 连续 7 日", statistics?.highSevenDays,
                       fallback: "尚无完整连续 7 日", color: usageColor, kind: .week)
                record("历史最低 · 连续 7 日", statistics?.lowSevenDays,
                       fallback: "尚无完整连续 7 日", color: lowColor, kind: .week)
                record("历史最高 · 单日", statistics?.highDay,
                       fallback: "尚无完整单日", color: usageColor, kind: .day)
                record("历史最高 · 单个时段", statistics?.highInterval,
                       fallback: "尚无有效时段", color: usageColor, kind: .interval)
            }
        }
        .padding(.top, 9)
        .overlay(alignment: .top) { separator.frame(height: 1) }
    }

    private enum RecordKind { case week, day, interval }

    private func record(_ title: String, _ value: HistoricalUsageRecord?, fallback: String,
                        color: Color, kind: RecordKind) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(secondary)
                .lineLimit(1)
            Text(value.map { $0.usedPercent.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—")
                .font(.system(size: 15, weight: .bold)).monospacedDigit()
                .foregroundStyle(value == nil ? secondary : color)
                .lineLimit(1)
            Text(value.map { dateLabel($0, kind: kind) } ?? fallback)
                .font(.system(size: 9)).foregroundStyle(secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(separator, lineWidth: 1))
        .help(value.map { dateLabel($0, kind: kind) } ?? fallback)
    }

    private func dateLabel(_ record: HistoricalUsageRecord, kind: RecordKind) -> String {
        let calendar = Calendar.current
        func formatted(_ date: Date, _ format: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        switch kind {
        case .week:
            return "\(formatted(record.startsAt, "M月d日"))–\(formatted(record.endsAt.addingTimeInterval(-1), "M月d日"))"
        case .day:
            return formatted(record.startsAt, "M月d日")
        case .interval:
            let lastInstant = record.endsAt.addingTimeInterval(-0.001)
            let endTime = calendar.isDate(record.startsAt, inSameDayAs: lastInstant)
                && !calendar.isDate(record.startsAt, inSameDayAs: record.endsAt)
                ? "24:00" : formatted(record.endsAt, "HH:mm")
            if calendar.isDate(record.startsAt, inSameDayAs: lastInstant) {
                return "\(formatted(record.startsAt, "M月d日 HH:mm"))–\(endTime)"
            }
            return "\(formatted(record.startsAt, "M月d日 HH:mm"))–\(formatted(record.endsAt, "M月d日 HH:mm"))"
        }
    }
}

private struct CapBarTotalTrendStatistics: View {
    let statistics: ProviderTrendStatistics
    let binHours: Int

    @Environment(\.colorScheme) private var colorScheme
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let separator = Color(nsColor: .separatorColor)
    private var usageColor: Color {
        colorScheme == .dark ? Color(red: 0.51, green: 0.73, blue: 1.0)
                             : Color(red: 0.14, green: 0.47, blue: 0.82)
    }
    private var coverageColor: Color {
        colorScheme == .dark ? Color(red: 0.43, green: 0.82, blue: 0.75)
                             : Color(red: 0.10, green: 0.55, blue: 0.49)
    }
    private var periodColor: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.74, blue: 0.43)
                             : Color(red: 0.69, green: 0.39, blue: 0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                primary(label: "最高 · 每 \(binHours) 小时", value: percent(statistics.peak?.value),
                        note: statistics.peak.map { peakTime($0.endAt) } ?? "数据不足", color: periodColor)
                divider
                primary(label: "最低 · 每 \(binHours) 小时", value: percent(statistics.minimum),
                        note: "有效区间含 0%", color: coverageColor)
                divider
                primary(label: "平均 · 每 \(binHours) 小时", value: percent(statistics.average),
                        note: "仅计算有效区间", color: usageColor)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { separator.frame(height: 1) }
            .overlay(alignment: .bottom) { separator.frame(height: 1) }
            .padding(.bottom, 6)

            HStack(spacing: 7) {
                Text("已观测合计").foregroundStyle(secondary)
                Text(percent(statistics.observedTotal)).fontWeight(.semibold).foregroundStyle(usageColor)
                Spacer(minLength: 2)
                Text("数据覆盖").foregroundStyle(secondary)
                Text("\(statistics.validBinCount)/\(statistics.expectedBinCount) 区间")
                    .fontWeight(.semibold).foregroundStyle(coverageColor)
            }
            .modifier(StatisticsRowStyle())

            HStack(spacing: 7) {
                Text("贡献最多").foregroundStyle(secondary).fixedSize()
                Text(statistics.leader?.label ?? "—")
                    .fontWeight(.semibold)
                    .foregroundStyle(statistics.leader == nil ? secondary : usageColor)
                    .lineLimit(1).truncationMode(.middle)
                    .help(statistics.leader?.label ?? "尚无账号用量")
                Spacer(minLength: 2)
                if let leader = statistics.leader {
                    Text("等效用量 \(percent(leader.equivalentPercent)) · 占比 \(percent(leader.sharePercent))")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(coverageColor).fixedSize()
                        .help("按首账号套餐换算的用量；占比为该账号在本服务已观测合计中的比例")
                }
            }
            .modifier(StatisticsRowStyle())

            HStack(spacing: 7) {
                if statistics.usagePeriodsAreUniform {
                    Text("时段分布").foregroundStyle(secondary)
                    Text("无明显差异").fontWeight(.semibold).foregroundStyle(secondary)
                } else {
                    Text("高用量时段").foregroundStyle(secondary).fixedSize()
                    Text(statistics.highUsagePeriod?.label ?? "数据不足")
                        .fontWeight(.semibold)
                        .foregroundStyle(statistics.highUsagePeriod == nil ? secondary : periodColor)
                    Spacer(minLength: 2)
                    Text("低用量时段").foregroundStyle(secondary).fixedSize()
                    Text(statistics.lowUsagePeriod?.label ?? "数据不足")
                        .fontWeight(.semibold)
                        .foregroundStyle(statistics.lowUsagePeriod == nil ? secondary : coverageColor)
                }
            }
            .help("按本地时间和已观测用量估算；缺测区间不计入")
            .modifier(StatisticsRowStyle())

            HStack(spacing: 7) {
                Text("最近 24 小时").foregroundStyle(secondary).fixedSize()
                Text(percent(statistics.recent24Hours.usedPercent))
                    .fontWeight(.semibold)
                    .foregroundStyle(statistics.recent24Hours.usedPercent == nil ? secondary : usageColor)
                Text("覆盖 \(statistics.recent24Hours.validBinCount)/\(statistics.recent24Hours.expectedBinCount)")
                    .font(.system(size: 9)).foregroundStyle(secondary).fixedSize()
                Spacer(minLength: 2)
                Text("较前 24 小时").foregroundStyle(secondary).fixedSize()
                Text(TrendStatisticsText.changeLabel(statistics.changePercent))
                    .fontWeight(.semibold)
                    .foregroundStyle(statistics.changePercent == nil ? secondary : Color(red: 0.17, green: 0.62, blue: 0.45))
                    .help(statistics.changePercent == nil ? "前一窗口采样不足或基线为零" : "与前一个完整 24 小时窗口相比")
            }
            .modifier(StatisticsRowStyle())
        }
        .font(.system(size: 10))
        .monospacedDigit()
    }

    private var divider: some View {
        separator.frame(width: 1, height: 43)
    }

    private func primary(label: String, value: String, note: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
            Text(value).font(.system(size: 15, weight: .bold))
                .foregroundStyle(value == "—" ? secondary : color).lineLimit(1)
            Text(note).font(.system(size: 8)).foregroundStyle(secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func peakTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

private struct StatisticsRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minHeight: 23).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

private struct CapBarAccountRow: View {
    let row: PopoverAccountRow
    let width: Int
    let statisticsEnabled: Bool
    let showsTrend: Bool
    let trend: UsageTrendSeries?
    let refresh: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let line = Color(nsColor: .separatorColor)

    var body: some View {
        Group {
            if PopoverLayout.usesWideRows(width: width) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            identity
                            Spacer(minLength: 2)
                            refreshButton
                        }
                        HStack(spacing: 7) {
                            captureTimeBadge
                            stateLabel
                        }
                    }
                    .frame(width: max(240, min(360, CGFloat(width) * 0.35)), alignment: .leading)
                    content.frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        identity
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            captureTimeBadge
                            stateLabel
                        }
                        refreshButton
                    }
                    content
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var captureTimeColor: Color {
        switch row.captureAgeBand {
        case .unknown: secondary
        case .fresh: Color(nsColor: .systemGreen)
        case .underTen: colorScheme == .dark
            ? Color(red: 0.76, green: 0.84, blue: 0.37)
            : Color(red: 0.36, green: 0.53, blue: 0.12)
        case .underThirty: colorScheme == .dark
            ? Color(red: 0.97, green: 0.80, blue: 0.30)
            : Color(red: 0.62, green: 0.43, blue: 0.06)
        case .underSixty: Color(nsColor: .systemOrange)
        case .old: Color(nsColor: .systemRed)
        }
    }

    private var captureTimeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
            Text(row.timeLabel).monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(captureTimeColor)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(captureTimeColor.opacity(0.12), in: Capsule())
        .accessibilityLabel("额度采集时间：\(row.timeLabel)")
        .help("额度采集时间：\(row.timeLabel)")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(row.title)
            HStack(spacing: 5) {
                Text(row.subtitle).lineLimit(1)
                Text("·")
                Text(row.directoryLabel).lineLimit(1)
                    .font(.system(size: 10, design: .monospaced))
                    .help(row.account.directory)
            }
            .font(.system(size: 10)).foregroundStyle(secondary)
        }
    }

    @ViewBuilder private var stateLabel: some View {
        if row.isRefreshing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                Text("刷新中")
            }
            .font(.system(size: 10)).foregroundStyle(Color.accentColor)
        } else if row.error != nil {
            Text("● 刷新失败").font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .systemRed))
                .help(row.error ?? "")
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .disabled(!row.refreshEnabled)
        .accessibilityLabel("刷新 \(row.title)")
        .help(row.isRefreshing ? "正在刷新" : "刷新此账号")
    }

    @ViewBuilder private var metrics: some View {
        if row.windows.isEmpty {
            Text("尚无快照 · 点击右侧刷新")
                .font(.system(size: 11)).foregroundStyle(secondary)
                .padding(.top, 1)
        } else {
            HStack(alignment: statisticsEnabled ? .center : .top, spacing: 0) {
                ForEach(Array(row.windows.enumerated()), id: \.offset) { index, window in
                    if index > 0 {
                        line.frame(width: 1, height: statisticsEnabled ? 54 : nil)
                            .padding(.horizontal, 14)
                    }
                    CapBarMetric(window: window, expanded: statisticsEnabled).frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if showsTrend {
            UsageTrendChart(series: trend)
        } else {
            metrics.frame(height: statisticsEnabled ? 84 : nil, alignment: .center)
        }
    }
}

private struct CapBarMetric: View {
    let window: QuotaWindow
    let expanded: Bool

    private var color: Color {
        if window.remainingPercent == 0 { return Color(nsColor: .systemRed) }
        if window.remainingPercent < 20 { return Color(nsColor: .systemOrange) }
        return Color(red: 0.20, green: 0.64, blue: 0.48)
    }

    private var percentage: String {
        let value = window.remainingPercent
        return value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func resetLabel(state: SevenDayResetState) -> String {
        guard let date = window.resetsAt else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date) + (window.kind == .sevenDay && state == .awaitingRefresh ? " · 待刷新" : " 重置")
    }

    var body: some View {
        let resetState = SevenDayResetState(resetsAt: window.resetsAt, now: Date())
        let weeklyExpired = window.kind == .sevenDay && resetState == .awaitingRefresh
        VStack(alignment: .leading, spacing: expanded ? 0 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.kind == .fiveHour ? "5 小时" : "7 天")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(weeklyExpired ? "上次余" : "余") \(percentage)%")
                    .font(.system(size: expanded ? 16 : 15, weight: .bold)).monospacedDigit()
                    .foregroundStyle(color.opacity(weeklyExpired ? 0.55 : 1))
            }
            if expanded { Spacer(minLength: 6) }
            GeometryReader { geometry in
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.75))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color.opacity(weeklyExpired ? 0.55 : 1))
                            .frame(width: max(0, geometry.size.width * window.remainingPercent / 100))
                    }
            }
            .frame(height: expanded ? 5 : 4)
            if expanded { Spacer(minLength: 6) }
            HStack(spacing: 9) {
                if window.kind == .sevenDay, case let .upcoming(progress) = resetState {
                    SevenDayResetRing(progress: progress)
                }
                Text(resetLabel(state: resetState)).font(.system(size: 11))
                    .foregroundStyle(weeklyExpired ? Color(nsColor: .systemOrange) : Color.secondary)
                    .monospacedDigit().lineLimit(1)
            }
        }
        .frame(height: expanded ? 84 : nil)
    }
}

private struct SevenDayResetRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { segment in
                let start = Double(segment) / 7 + 0.02
                let end = Double(segment + 1) / 7 - 0.02
                Circle().trim(from: start, to: end)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                if progress > start {
                    Circle().trim(from: start, to: min(end, progress))
                        .stroke(Color(nsColor: .systemBlue).opacity(0.8), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .frame(width: 15, height: 15)
        .animation(.easeInOut(duration: 0.35), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("七日重置周期已过 \(Int((progress * 100).rounded()))%")
    }
}
