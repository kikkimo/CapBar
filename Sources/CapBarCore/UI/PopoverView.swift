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
        .frame(width: 448, height: 620)
        .background(.regularMaterial)
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
                Text("\(model.rows.count) 个账号 · \(model.settings.autoRefreshOnOpen ? "打开时按需刷新" : "仅手动刷新")")
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
        ScrollView {
            VStack(spacing: 0) {
                let exhausted = PopoverPresentation.exhaustedCount(rows: model.rows)
                if exhausted > 0 {
                    HStack(spacing: 7) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("\(exhausted) 个账号额度已用尽 · 请查看下方账号")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color(nsColor: .systemRed).opacity(0.08))
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ForEach(rows, id: \.account) { row in
                CapBarAccountRow(row: row) { model.refresh(row.account) }
                    .padding(.horizontal, 16)
                if row.account != rows.last?.account {
                    line.frame(height: 1).padding(.horizontal, 16)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("额度为剩余百分比 · 时间为本地时间")
                .font(.system(size: 10)).foregroundStyle(secondary)
            Spacer()
            Button(model.showsSettings ? "返回总览" : "账号与设置") {
                model.showsSettings.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.58))
        .overlay(alignment: .top) { line.frame(height: 1) }
    }
}

private struct CapBarAccountRow: View {
    let row: PopoverAccountRow
    let refresh: () -> Void

    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let line = Color(nsColor: .separatorColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
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
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(row.timeLabel).font(.system(size: 10)).foregroundStyle(secondary)
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
            if row.windows.isEmpty {
                Text("尚无快照 · 点击右侧刷新")
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .padding(.top, 1)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.windows.enumerated()), id: \.offset) { index, window in
                        if index > 0 { line.frame(width: 1).padding(.horizontal, 14) }
                        CapBarMetric(window: window).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .leading) {
            if row.isExhausted {
                Color(nsColor: .systemRed).frame(width: 2).offset(x: -16)
            }
        }
    }
}

private struct CapBarMetric: View {
    let window: QuotaWindow

    private var color: Color {
        if window.remainingPercent == 0 { return Color(nsColor: .systemRed) }
        if window.remainingPercent < 20 { return Color(nsColor: .systemOrange) }
        return Color(red: 0.20, green: 0.64, blue: 0.48)
    }

    private var percentage: String {
        let value = window.remainingPercent
        return value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private var reset: String {
        guard let date = window.resetsAt else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date) + " 重置"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.kind == .fiveHour ? "5 小时" : "7 天")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("余 \(percentage)%")
                    .font(.system(size: 15, weight: .bold)).monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { geometry in
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.75))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: max(0, geometry.size.width * window.remainingPercent / 100))
                    }
            }
            .frame(height: 4)
            Text(reset).font(.system(size: 11)).foregroundStyle(.secondary)
                .monospacedDigit().lineLimit(1)
        }
    }
}
