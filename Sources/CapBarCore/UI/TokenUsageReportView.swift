import AppKit
import Combine
import SwiftUI

@MainActor final class TokenReportModel: ObservableObject {
    let source: TokenUsageController
    @Published var labels: [AccountID: String]
    @Published var query: TokenReportQuery
    @Published var sortOrder = [KeyPathComparator<TokenReportRow>(\.primary, order: .reverse)]
    init(source: TokenUsageController, labels: [AccountID: String]) {
        self.source = source; self.labels = labels
        query = TokenReportQuery(range: source.range, period: source.period, provider: source.provider, account: source.account)
    }
    var result: TokenReportResult { .build(events: source.events, sources: source.sources, labels: labels, query: query) }
}

/// A normal app window: no modal session, sheet, child window, or popover owner.
@MainActor final class TokenUsageReportWindowController: NSWindowController {
    let report: TokenReportModel
    init(source: TokenUsageController, labels: [AccountID: String]) {
        report = TokenReportModel(source: source, labels: labels)
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1680, screen.width - 64), height: min(1000, screen.height - 64))
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "用量详细报表 · CapBar"
        panel.minSize = NSSize(width: 1000, height: 580)
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenPrimary]
        let hosting = NSHostingController(rootView: TokenUsageReportView(report: report))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        // Hosting may adopt the view's minimum fitting size; apply the intended
        // reading area after installing the content controller.
        panel.setContentSize(size)
        super.init(window: panel)
        panel.center()
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.deminiaturize(nil)
    }
}

struct TokenUsageReportView: View {
    @ObservedObject var report: TokenReportModel
    @ObservedObject private var source: TokenUsageController
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searching: Bool
    @State private var selection: Set<TokenReportRow.ID> = []
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let separator = Color(nsColor: .separatorColor)
    init(report: TokenReportModel) { self.report = report; self.source = report.source }
    var body: some View {
        let result = report.result
        VStack(spacing: 0) {
            heading
            VStack(spacing: 16) {
                filters
                HStack(spacing: 12) {
                    metric("总 token", value: TokenDisplay.millions(result.total.tokens.total), caption: "含缓存读写", color: .primary)
                    metric("API 等价金额", value: TokenDisplay.money(result.total), caption: "USD · 按模型价格估算", color: .accentColor)
                    metric("账号", value: String(result.accountCount), caption: "当前筛选范围", color: .primary)
                    metric("模型", value: String(result.modelCount), caption: "当前筛选范围", color: .primary)
                }
                tableCard(result)
            }.padding(20)
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text("本机日志 · 本地时间 · API 等价估算，不代表实际账单")
                Spacer()
                if let last = source.lastSuccess { Text("扫描于 " + last.formatted(.dateTime.month().day().hour().minute())) }
            }.font(.system(size: 11)).foregroundStyle(secondary).padding(.horizontal, 22).padding(.bottom, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: report.query.provider) { _, provider in
            if let account = report.query.account, let provider, account.provider != provider { report.query.account = nil }
        }
        .onChange(of: source.sources) { _, accounts in
            if let account = report.query.account, !accounts.contains(account) { report.query.account = nil }
        }
    }
    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 23)).foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("用量详细报表").font(.system(size: 23, weight: .semibold))
                Text("按账号和模型查阅 · 点击表头排序").font(.system(size: 12)).foregroundStyle(secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).keyboardShortcut("f", modifiers: .command).help("搜索账号、模型或目录（⌘F）").accessibilityLabel("聚焦报表搜索")
                TextField("搜索账号、模型、目录或日期", text: $report.query.search).textFieldStyle(.plain).focused($searching).accessibilityLabel("搜索报表")
                if !report.query.search.isEmpty {
                    Button { report.query.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(secondary) }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.font(.system(size: 13)).padding(10).frame(width: 300)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(searching ? Color.accentColor : separator.opacity(0.6)))
        }.padding(.horizontal, 24).padding(.vertical, 20)
            .background(LinearGradient(colors: [Color.accentColor.opacity(scheme == .dark ? 0.07 : 0.035), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .bottom) { separator.opacity(0.5).frame(height: 1) }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("时间范围", selection: Binding(get: { report.query.period }, set: { report.query.select($0) })) {
                    ForEach(TokenPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                if report.query.period == .custom {
                    DatePicker("从", selection: $report.query.start, displayedComponents: .date).datePickerStyle(.field)
                    DatePicker("至", selection: $report.query.end, displayedComponents: .date).datePickerStyle(.field)
                } else if let range = report.query.range(calendar: .current) {
                    Text(TokenDisplay.dateRange(range)).foregroundStyle(secondary)
                }
                Spacer(minLength: 0)
                Button("重置筛选", systemImage: "arrow.counterclockwise") {
                    report.query = TokenReportQuery(range: .preset(.sevenDays, now: Date(), calendar: .current))
                }.controlSize(.small)
            }
            HStack(spacing: 16) {
                Picker("工具", selection: $report.query.provider) {
                    Text("全部工具").tag(Optional<Provider>.none)
                    Text("Claude Code").tag(Optional(Provider.claude)); Text("Codex").tag(Optional(Provider.codex))
                }.frame(width: 170)
                Picker("账号", selection: $report.query.account) {
                    Text("全部账号").tag(Optional<AccountID>.none)
                    ForEach(source.sources.filter { report.query.provider == nil || $0.provider == report.query.provider }, id: \.self) { account in
                        Text(report.labels[account] ?? (account.directory as NSString).abbreviatingWithTildeInPath).tag(Optional(account))
                    }
                }.frame(width: 270)
                Spacer()
                if report.query.range(calendar: .current) == nil { Label("开始日期不能晚于结束日期", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            }
        }.font(.system(size: 12))
    }
    private func metric(_ title: String, value: String, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
            Text(value).font(.system(size: 27, weight: .semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 11)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(separator.opacity(0.45)))
    }
    private func tableCard(_ result: TokenReportResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("报表分组", selection: $report.query.scope) {
                    ForEach(TokenReportScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 480)
                Spacer()
                Text("\(result.rows.count) 行").font(.system(size: 12)).foregroundStyle(secondary)
            }.padding(14)
            Divider()
            dataTable(result.rows)
                .overlay { if result.rows.isEmpty {
                    ContentUnavailableView("没有匹配的用量", systemImage: "magnifyingglass", description: Text("调整时间、账号或搜索条件后重试。"))
                } }
            Divider()
            HStack(spacing: 18) {
                Text("筛选合计").fontWeight(.semibold)
                Text(result.total.tokens.total.formatted() + " token").monospacedDigit()
                Text(TokenDisplay.money(result.total)).monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.accentColor)
                Spacer()
                Text("可拖动列宽、横向滚动 · “+”含未定价用量").foregroundStyle(secondary)
            }.font(.system(size: 12)).padding(14).background(Color.accentColor.opacity(scheme == .dark ? 0.08 : 0.035))
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(separator.opacity(0.6)))
    }
    private func dataTable(_ rows: [TokenReportRow]) -> some View {
        Group {
            if report.query.scope == .detail {
            Table(rows.sorted(using: report.sortOrder), selection: $selection, sortOrder: $report.sortOrder) {
                TableColumn(report.query.scope.columnTitle, value: \.primary) { row in
                    Text(row.primary).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(row.primary)
                }.width(min: 90, ideal: report.query.scope == .detail || report.query.scope == .day || report.query.scope == .month ? 115 : 220, max: 280)
                TableColumn("账号", value: \.account) { row in
                    Text(row.account).lineLimit(1).truncationMode(.middle).help(row.bucket.account?.directory ?? row.account)
                }.width(min: 130, ideal: 155, max: 260)
                TableColumn("工具", value: \.tool) { row in
                    HStack(spacing: 5) {
                        if row.bucket.provider != nil { Circle().fill(TokenProviderStyle.color(row.bucket.provider, scheme: scheme)).frame(width: 5, height: 5) }
                        Text(row.tool).font(.system(size: 11)).lineLimit(1)
                    }
                }.width(min: 80, ideal: 90, max: 110)
                TableColumn("模型", value: \.model) { row in Text(row.model).lineLimit(1).truncationMode(.middle).help(row.model) }.width(min: 130, ideal: 155, max: 260)
                metricColumns
            }
            } else {
                Table(rows.sorted(using: report.sortOrder), selection: $selection, sortOrder: $report.sortOrder) {
                    TableColumn(report.query.scope.columnTitle, value: \.primary) { row in
                        Text(row.primary).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(row.primary)
                    }.width(min: 170, ideal: 240, max: 400)
                    TableColumn("工具", value: \.tool) { row in
                        HStack(spacing: 5) {
                            if row.bucket.provider != nil { Circle().fill(TokenProviderStyle.color(row.bucket.provider, scheme: scheme)).frame(width: 5, height: 5) }
                            Text(row.tool).lineLimit(1)
                        }
                    }.width(min: 80, ideal: 100, max: 140)
                    metricColumns
                }
            }
        }.tableStyle(.inset(alternatesRowBackgrounds: true)).font(.system(size: 12))
    }
    @TableColumnBuilder<TokenReportRow, KeyPathComparator<TokenReportRow>>
    private var metricColumns: some TableColumnContent<TokenReportRow, KeyPathComparator<TokenReportRow>> {
        TableColumn("非缓存输入", value: \.input) { row in number(row.input) }.width(min: 90, ideal: 100, max: 160)
        TableColumn("输出", value: \.output) { row in number(row.output) }.width(min: 80, ideal: 90, max: 160)
        TableColumn("缓存写入", value: \.cacheWrite) { row in number(row.cacheWrite) }.width(min: 90, ideal: 100, max: 160)
        TableColumn("缓存读取", value: \.cacheRead) { row in number(row.cacheRead) }.width(min: 90, ideal: 110, max: 170)
        TableColumn("总 token", value: \.total) { row in number(row.total).fontWeight(.semibold) }.width(min: 100, ideal: 115, max: 170)
        TableColumn("API 等价 USD", value: \.cost) { row in
            Text(TokenDisplay.money(row.bucket)).monospacedDigit().fontWeight(.medium).foregroundStyle(selection.contains(row.id) ? Color(nsColor: .selectedControlTextColor) : Color.accentColor).frame(maxWidth: .infinity, alignment: .trailing)
        }.width(min: 100, ideal: 110, max: 170)
    }
    private func number(_ value: Int64) -> some View {
        Text(value.formatted()).monospacedDigit().lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
    }
}
