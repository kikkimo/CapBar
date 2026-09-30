import Foundation
@testable import CapBarCore

@MainActor func runUsageTrendChartChecks() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let end = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
    let series = UsageTrendCalculator.calculate(samples: [], intervalHours: 4, endingAt: end)
    let labels = UsageTrendChartLayout.dateLabels(points: series.points, binHours: series.binHours, calendar: calendar)
    check(labels.map(\.text) == ["21", "22", "23", "24", "25", "26", "27", "28"], "chart labels every local calendar day in rolling week")
    check(UsageTrendChartText.intervalUsageLabel(binHours: series.binHours) == "这 4 小时用量",
          "tooltip describes the selected chart interval")
    check(UsageTrendChartText.intervalUsageLabel(binHours: 4, isTotal: true) == "这 4 小时合计用量",
          "total tooltip distinguishes weighted aggregate usage from one account")
    check(UsageTrendChartLayout.nearestPointIndex(at: 26, width: 416, count: 84) == 0, "hover at left edge picks oldest point")
    check(UsageTrendChartLayout.nearestPointIndex(at: 408, width: 416, count: 84) == 83, "hover at right edge picks latest point")
    check(abs(UsageTrendChartLayout.yPosition(value: 0, axisMaximum: 60, height: 84) - 63) < 0.01, "zero usage is at graph baseline")
    check(abs(UsageTrendChartLayout.yPosition(value: 60, axisMaximum: 60, height: 84) - 8) < 0.01, "axis maximum is at graph top")
    let lowColor = UsageTrendColorScale.turboRGB(at: 0)
    let midColor = UsageTrendColorScale.turboRGB(at: 0.5)
    let highColor = UsageTrendColorScale.turboRGB(at: 1)
    check(lowColor.blue > lowColor.red && highColor.red > highColor.blue && midColor.green > lowColor.green,
          "trend palette moves from cool low usage through green to warm high usage")
    check(UsageTrendColorScale.turboRGB(at: -1) == lowColor && UsageTrendColorScale.turboRGB(at: 2) == highColor,
          "trend palette clamps out-of-range values")
    check(TotalTrendBreakdownScale.maximumPercent == 20
          && abs(TotalTrendBreakdownScale.barFraction(3) - 0.15) < 0.001
          && abs(TotalTrendBreakdownScale.barFraction(5) - 0.25) < 0.001,
          "each contribution bar uses the fixed 0–20% scale")
    check(TotalTrendBreakdownScale.barFraction(0) == 0
          && TotalTrendBreakdownScale.barFraction(20) == 1
          && TotalTrendBreakdownScale.barFraction(27) == 1
          && TotalTrendBreakdownScale.barFraction(-3) == 0
          && TotalTrendBreakdownScale.barFraction(.nan) == 0,
          "empty, full and overflow contribution bars stay within their track")

    let now = ISO8601DateFormatter().date(from: "2026-09-28T04:25:00Z")!
    let next = ISO8601DateFormatter().date(from: "2026-09-28T08:00:00Z")!
    let pending = UsageTrendEmptyState.lines(sampleCount: 3, binHours: 4, nextSampleAt: next, now: now, calendar: calendar)
    check(pending == [
        "近 7 日已采样 3 次",
        "尚未覆盖完整的 4 小时区间",
        "预计今天 16:00 自动采样；也可手动刷新"
    ], "empty chart explains three recorded samples and the next local sampling time")
    let tomorrow = ISO8601DateFormatter().date(from: "2026-09-28T16:00:00Z")!
    check(UsageTrendEmptyState.lines(sampleCount: 0, binHours: 4, nextSampleAt: tomorrow, now: now, calendar: calendar)[2]
          == "预计明天 00:00 自动采样；也可手动刷新", "next sampling time follows the local date")
    check(UsageTrendEmptyState.lines(sampleCount: 1, binHours: 2, nextSampleAt: nil, now: now, calendar: calendar)[2]
          == "等待下次定时采样；也可手动刷新", "missing scheduler time avoids inventing a sampling hour")

    let hour: TimeInterval = 3_600
    let singleSeries = UsageTrendCalculator.calculate(
        samples: [
            UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 3.62 * hour), usedPercent: 26, resetsAt: Date(timeIntervalSince1970: 80 * hour)),
            UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 4.01 * hour), usedPercent: 26, resetsAt: Date(timeIntervalSince1970: 80 * hour)),
            UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 4.4 * hour), usedPercent: 27, resetsAt: Date(timeIntervalSince1970: 80 * hour)),
            UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 6.03 * hour), usedPercent: 28, resetsAt: Date(timeIntervalSince1970: 80 * hour))
        ], intervalHours: 2, endingAt: Date(timeIntervalSince1970: 6.05 * hour)
    )
    check(singleSeries.points.compactMap(\.usedPercent).count == 1, "first completed two-hour interval yields exactly one usage point")
    check(UsageTrendChartLayout.standalonePointIndex(points: singleSeries.points) == 83,
          "chart marks a valid usage point even before there is a second point to connect")
    check(UsageTrendChartLayout.standalonePointIndex(points: series.points) == nil,
          "empty chart has no standalone usage marker")
    let twoPoints = singleSeries.points + [UsageTrendPoint(
        endAt: Date(timeIntervalSince1970: 8 * hour), usedPercent: 0,
        remainingPercent: 72, crossesReset: false, isEstimated: false
    )]
    check(UsageTrendChartLayout.standalonePointIndex(points: twoPoints) == nil,
          "two valid points use their connecting line, including a zero-usage point")
    let withGap = [twoPoints[83], UsageTrendPoint(
        endAt: Date(timeIntervalSince1970: 7 * hour), usedPercent: nil,
        remainingPercent: nil, crossesReset: false, isEstimated: false
    ), twoPoints[84]]
    check(UsageTrendChartLayout.lineSegments(points: withGap, connectMissing: false).isEmpty,
          "total trend leaves an unobserved interval blank")
    check(UsageTrendChartLayout.isolatedPointIndices(points: withGap) == [0, 2],
          "observed points beside missing intervals remain visible")
}
