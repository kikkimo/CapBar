import SwiftUI

enum UsageTrendChartText {
    static func intervalUsageLabel(binHours: Int, isTotal: Bool = false) -> String {
        "这 \(binHours) 小时\(isTotal ? "合计" : "")用量"
    }
}

enum UsageTrendEmptyState {
    static func lines(sampleCount: Int, binHours: Int, nextSampleAt: Date?, now: Date, calendar: Calendar) -> [String] {
        let count = "近 7 日已采样 \(sampleCount) 次"
        let reason = sampleCount == 0 ? "尚无历史采样记录" : "尚未覆盖完整的 \(binHours) 小时区间"
        guard let nextSampleAt else {
            return [count, reason, "等待下次定时采样；也可手动刷新"]
        }
        guard nextSampleAt > now else {
            return [count, reason, "定时采样即将执行；也可手动刷新"]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let day: String
        if calendar.isDate(nextSampleAt, inSameDayAs: now) {
            day = "今天"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(nextSampleAt, inSameDayAs: tomorrow) {
            day = "明天"
        } else {
            formatter.dateFormat = "M月d日"
            day = formatter.string(from: nextSampleAt)
            formatter.dateFormat = "HH:mm"
        }
        return [count, reason, "预计\(day) \(formatter.string(from: nextSampleAt)) 自动采样；也可手动刷新"]
    }
}

struct UsageTrendDateLabel {
    let index: Int
    let text: String
}

struct UsageTrendLineSegment {
    let from: Int
    let to: Int
    let dashed: Bool
}

enum UsageTrendChartLayout {
    static let leading: CGFloat = 26
    static let trailing: CGFloat = 8
    static let top: CGFloat = 8
    static let bottomInset: CGFloat = 21

    static func dateLabels(points: [UsageTrendPoint], binHours: Int, calendar: Calendar) -> [UsageTrendDateLabel] {
        var groups: [(day: DateComponents, first: Int, last: Int)] = []
        for (index, point) in points.enumerated() {
            let midpoint = point.endAt.addingTimeInterval(-Double(binHours) * 1_800)
            let day = calendar.dateComponents([.era, .year, .month, .day], from: midpoint)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].last = index
            } else {
                groups.append((day, index, index))
            }
        }
        return groups.map { group in
            UsageTrendDateLabel(index: (group.first + group.last) / 2, text: String(group.day.day ?? 0))
        }
    }

    static func nearestPointIndex(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let span = max(1, width - leading - trailing)
        let fraction = min(1, max(0, (x - leading) / span))
        return Int((fraction * CGFloat(count - 1)).rounded())
    }

    static func xPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return leading }
        return leading + CGFloat(index) / CGFloat(count - 1) * max(1, width - leading - trailing)
    }

    static func yPosition(value: Double, axisMaximum: Double, height: CGFloat) -> CGFloat {
        let floorY = height - bottomInset
        let fraction = min(1, max(0, value / max(1, axisMaximum)))
        return floorY - CGFloat(fraction) * (floorY - top)
    }

    static func standalonePointIndex(points: [UsageTrendPoint]) -> Int? {
        let validIndices = points.indices.filter { points[$0].usedPercent != nil }
        return validIndices.count == 1 ? validIndices[0] : nil
    }

    static func lineSegments(points: [UsageTrendPoint], connectMissing: Bool) -> [UsageTrendLineSegment] {
        var result: [UsageTrendLineSegment] = []
        var previous: Int?
        for index in points.indices where points[index].usedPercent != nil {
            if let previous, connectMissing || index == previous + 1 {
                result.append(UsageTrendLineSegment(
                    from: previous, to: index,
                    dashed: connectMissing && (index != previous + 1 || points[index].crossesReset)
                ))
            }
            previous = index
        }
        return result
    }

    static func isolatedPointIndices(points: [UsageTrendPoint]) -> [Int] {
        points.indices.filter { index in
            points[index].usedPercent != nil
                && (index == 0 || points[index - 1].usedPercent == nil)
                && (index == points.count - 1 || points[index + 1].usedPercent == nil)
        }
    }
}

struct UsageTrendChart: View {
    let series: UsageTrendSeries?
    var calendar: Calendar = .current
    var colorRange: ClosedRange<Double>? = nil
    var totalOverview: ProviderTrendOverview? = nil

    @State private var hoveredIndex: Int?
    private var chartHeight: CGFloat { totalOverview == nil ? 84 : 128 }
    private let secondary = Color(nsColor: .secondaryLabelColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                if let series, series.points.contains(where: { $0.usedPercent != nil }) {
                    chart(series: series, size: geometry.size)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredIndex = UsageTrendChartLayout.nearestPointIndex(
                                    at: location.x, width: geometry.size.width, count: series.points.count
                                )
                            case .ended:
                                hoveredIndex = nil
                            }
                        }
                } else if let series {
                    let lines = UsageTrendEmptyState.lines(
                        sampleCount: series.sampleCount, binHours: series.binHours, nextSampleAt: series.nextSampleAt,
                        now: Date(), calendar: calendar
                    )
                    VStack(spacing: 5) {
                        Text(lines[0]).font(.system(size: 11, weight: .semibold))
                        Text(lines[1]).font(.system(size: 10)).foregroundStyle(secondary)
                        Text(lines[2]).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                } else {
                    Text("正在读取历史采样记录…")
                        .font(.system(size: 10)).foregroundStyle(secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
            }
            .frame(height: chartHeight)
            if let totalOverview, let series, let hoveredIndex,
               series.points.indices.contains(hoveredIndex) {
                TotalTrendTooltip(point: series.points[hoveredIndex], series: series,
                                  overview: totalOverview, calendar: calendar)
                    .padding(.leading, UsageTrendChartLayout.leading)
                    .padding(.trailing, UsageTrendChartLayout.trailing)
                    .padding(.top, 7)
            }
        }
    }

    private func chart(series: UsageTrendSeries, size: CGSize) -> some View {
        let isTotal = totalOverview != nil
        let segments = UsageTrendChartLayout.lineSegments(points: series.points, connectMissing: !isTotal)
        let range = colorRange ?? UsageTrendColorScale.range(for: [series])
        return ZStack(alignment: .topLeading) {
            ForEach(Array(series.axisTicks.enumerated()), id: \.offset) { index, tick in
                let y = UsageTrendChartLayout.yPosition(value: tick, axisMaximum: series.axisMaximum, height: size.height)
                Path { path in
                    path.move(to: CGPoint(x: UsageTrendChartLayout.leading, y: y))
                    path.addLine(to: CGPoint(x: size.width - UsageTrendChartLayout.trailing, y: y))
                }
                .stroke(secondary.opacity(index == 0 || index == series.axisTicks.count - 1 ? 0.27 : 0.16), lineWidth: 0.7)
                Text(percent(tick))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(secondary)
                    .position(x: 11, y: y)
            }
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                let from = coordinate(for: segment.from, points: series.points, size: size, maximum: series.axisMaximum)
                let to = coordinate(for: segment.to, points: series.points, size: size, maximum: series.axisMaximum)
                Path { path in
                    path.move(to: from)
                    let delta = to.x - from.x
                    path.addCurve(
                        to: to,
                        control1: CGPoint(x: from.x + delta * 0.42, y: from.y),
                        control2: CGPoint(x: to.x - delta * 0.42, y: to.y)
                    )
                }
                .stroke(LinearGradient(
                    colors: (0...4).map { step in
                        let start = series.points[segment.from].usedPercent ?? 0
                        let end = series.points[segment.to].usedPercent ?? 0
                        return trendColor(start + (end - start) * Double(step) / 4, range: range)
                    }, startPoint: .leading, endPoint: .trailing
                ), style: StrokeStyle(
                    lineWidth: 1.8, lineCap: .round, lineJoin: .round,
                    dash: segment.dashed ? [3.5, 3] : []
                ))
            }
            ForEach(isTotal ? UsageTrendChartLayout.isolatedPointIndices(points: series.points)
                    : UsageTrendChartLayout.standalonePointIndex(points: series.points).map { [$0] } ?? [], id: \.self) { index in
                let usage = series.points[index].usedPercent ?? 0
                let point = coordinate(for: index, points: series.points, size: size, maximum: series.axisMaximum)
                Circle()
                    .fill(trendColor(usage, range: range))
                    .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .position(point)
                if !isTotal {
                    Text(percent(usage))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(trendColor(usage, range: range))
                        .position(x: max(UsageTrendChartLayout.leading + 16, point.x - 18),
                                  y: max(UsageTrendChartLayout.top + 6, point.y - 13))
                }
            }
            ForEach(UsageTrendChartLayout.dateLabels(points: series.points, binHours: series.binHours, calendar: calendar), id: \.index) { label in
                Text(label.text)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(secondary)
                    .position(
                        x: UsageTrendChartLayout.xPosition(index: label.index, count: series.points.count, width: size.width),
                        y: size.height - 5
                    )
            }
            if let hoveredIndex, series.points.indices.contains(hoveredIndex) {
                let point = series.points[hoveredIndex]
                let x = UsageTrendChartLayout.xPosition(index: hoveredIndex, count: series.points.count, width: size.width)
                Path { path in
                    path.move(to: CGPoint(x: x, y: UsageTrendChartLayout.top))
                    path.addLine(to: CGPoint(x: x, y: size.height - UsageTrendChartLayout.bottomInset))
                }
                .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                if let usage = point.usedPercent {
                    Circle()
                        .fill(trendColor(usage, range: range))
                        .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                        .position(x: x, y: UsageTrendChartLayout.yPosition(value: usage, axisMaximum: series.axisMaximum, height: size.height))
                }
                if !isTotal {
                    individualTooltip(for: point, series: series, range: range)
                        .frame(width: 166)
                        .position(x: min(max(83, x), max(83, size.width - 83)), y: -29)
                        .zIndex(3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func individualTooltip(for point: UsageTrendPoint, series: UsageTrendSeries,
                                   range: ClosedRange<Double>?) -> some View {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return VStack(alignment: .leading, spacing: 3) {
            Text(formatter.string(from: point.endAt) + " · 本地时间")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondary)
            HStack {
                Text("7 天额度剩余").foregroundStyle(secondary)
                Spacer(minLength: 4)
                Text(point.remainingPercent.map(percent) ?? "—")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.bold)
            }
            HStack {
                Text(UsageTrendChartText.intervalUsageLabel(binHours: series.binHours)).foregroundStyle(secondary)
                Spacer(minLength: 4)
                Text(point.usedPercent.map(percent) ?? "—")
                    .foregroundStyle(point.usedPercent.map { trendColor($0, range: range) } ?? secondary)
                    .fontWeight(.bold)
            }
            Text(point.isMissing ? "缺测区间，额度未知" : point.crossesReset ? "跨重置区间" : point.isEstimated ? "线性估算" : "采样值")
                .font(.system(size: 9)).foregroundStyle(secondary)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
        .allowsHitTesting(false)
    }

    private func coordinate(for index: Int, points: [UsageTrendPoint], size: CGSize, maximum: Double) -> CGPoint {
        CGPoint(
            x: UsageTrendChartLayout.xPosition(index: index, count: points.count, width: size.width),
            y: UsageTrendChartLayout.yPosition(value: points[index].usedPercent ?? 0, axisMaximum: maximum, height: size.height)
        )
    }

    private func trendColor(_ value: Double, range: ClosedRange<Double>?) -> Color {
        guard totalOverview != nil else { return .accentColor }
        let rgb = UsageTrendColorScale.turboRGB(at: UsageTrendColorScale.fraction(value, in: range))
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func percent(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }
}

struct TotalTrendTooltip: View {
    let point: UsageTrendPoint
    let series: UsageTrendSeries
    let overview: ProviderTrendOverview
    let calendar: Calendar

    private var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    private var contributions: [TrendContribution]? { overview.contributions(at: point.endAt) }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: point.endAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateLabel + " · 本地时间")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("这 \(series.binHours) 小时合计用量")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Text(point.usedPercent.map(percent) ?? "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(point.usedPercent.map { scaleColor($0, in: UsageTrendColorScale.range(for: [series])) } ?? secondary)
            }
            .padding(.top, 5)
            Text(point.isMissing ? "采样覆盖不足" : "以 \(overview.baselinePlan?.displayName ?? "套餐") 为基准 · \(overview.accountCount) 个账号")
                .font(.system(size: 10))
                .foregroundStyle(secondary)
                .padding(.top, 2)

            if let contributions {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.8))
                    .frame(height: 1).padding(.vertical, 9)
                HStack {
                    Text("账号列表")
                    Spacer(minLength: 4)
                    Text("估算等效使用量")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondary)
                .padding(.bottom, 5)
                ForEach(contributions.indices, id: \.self) { index in
                    let contribution = contributions[index]
                    HStack(spacing: 10) {
                        Text(contribution.label)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(Color.primary)
                            .frame(width: 180, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule().fill(Color(nsColor: .separatorColor).opacity(0.44))
                            if contribution.equivalentPercent > 0 {
                                LinearGradient(colors: (0...20).map { step in
                                    scaleColor(Double(step), in: 0...TotalTrendBreakdownScale.maximumPercent)
                                }, startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width, height: 7)
                                .frame(width: geometry.size.width * TotalTrendBreakdownScale.barFraction(
                                    contribution.equivalentPercent
                                ), height: 7, alignment: .leading)
                                .clipped()
                                .clipShape(Capsule())
                            }
                        }
                        .frame(height: 7)
                        Text(percent(contribution.equivalentPercent))
                            .fontWeight(.bold).monospacedDigit()
                            .foregroundStyle(scaleColor(contribution.equivalentPercent,
                                                        in: 0...TotalTrendBreakdownScale.maximumPercent))
                            .frame(width: 35, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .frame(height: 26)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7)))
        .shadow(color: .black.opacity(0.24), radius: 11, y: 5)
        .allowsHitTesting(false)
    }

    private func percent(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    private func scaleColor(_ value: Double, in range: ClosedRange<Double>?) -> Color {
        let rgb = UsageTrendColorScale.turboRGB(at: UsageTrendColorScale.fraction(value, in: range))
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

enum TotalTrendBreakdownScale {
    static let maximumPercent = 20.0

    static func barFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value / maximumPercent))
    }
}
