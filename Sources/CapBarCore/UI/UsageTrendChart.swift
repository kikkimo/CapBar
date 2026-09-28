import SwiftUI

struct UsageTrendDateLabel {
    let index: Int
    let text: String
}

enum UsageTrendChartLayout {
    static let leading: CGFloat = 26
    static let trailing: CGFloat = 8
    static let top: CGFloat = 8
    static let bottomInset: CGFloat = 21

    static func dateLabels(points: [UsageTrendPoint], calendar: Calendar) -> [UsageTrendDateLabel] {
        var groups: [(day: DateComponents, first: Int, last: Int)] = []
        for (index, point) in points.enumerated() {
            let day = calendar.dateComponents([.era, .year, .month, .day], from: point.endAt)
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
}

struct UsageTrendChart: View {
    let series: UsageTrendSeries?
    var calendar: Calendar = .current

    @State private var hoveredIndex: Int?
    private let chartHeight: CGFloat = 84
    private let secondary = Color(nsColor: .secondaryLabelColor)

    var body: some View {
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
            } else {
                VStack(spacing: 3) {
                    Text("数据不足，等待下一个采样点")
                        .font(.system(size: 10, weight: .medium))
                    Text("没有观测的数据不会记作 0% 用量")
                        .font(.system(size: 9))
                }
                .foregroundStyle(secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
        .frame(height: chartHeight)
    }

    private func chart(series: UsageTrendSeries, size: CGSize) -> some View {
        let segments = lineSegments(points: series.points)
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
                .stroke(Color.accentColor, style: StrokeStyle(
                    lineWidth: 1.8, lineCap: .round, lineJoin: .round,
                    dash: segment.dashed ? [3.5, 3] : []
                ))
            }
            ForEach(UsageTrendChartLayout.dateLabels(points: series.points, calendar: calendar), id: \.index) { label in
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
                        .fill(Color.accentColor)
                        .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                        .position(x: x, y: UsageTrendChartLayout.yPosition(value: usage, axisMaximum: series.axisMaximum, height: size.height))
                }
                tooltip(for: point)
                    .frame(width: 166)
                    .position(x: min(max(83, x), max(83, size.width - 83)), y: -29)
                    .zIndex(3)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func tooltip(for point: UsageTrendPoint) -> some View {
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
                Text("这 2 小时用量").foregroundStyle(secondary)
                Spacer(minLength: 4)
                Text(point.usedPercent.map(percent) ?? "—").fontWeight(.bold)
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

    private func lineSegments(points: [UsageTrendPoint]) -> [(from: Int, to: Int, dashed: Bool)] {
        var result: [(from: Int, to: Int, dashed: Bool)] = []
        var previous: Int?
        for index in points.indices where points[index].usedPercent != nil {
            if let previous {
                result.append((previous, index, index != previous + 1 || points[index].crossesReset))
            }
            previous = index
        }
        return result
    }

    private func percent(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }
}
