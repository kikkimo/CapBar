import Foundation
@testable import CapBarCore

@MainActor func runUsageTrendChartChecks() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let end = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
    let series = UsageTrendCalculator.calculate(samples: [], intervalHours: 4, endingAt: end)
    let labels = UsageTrendChartLayout.dateLabels(points: series.points, calendar: calendar)
    check(labels.map(\.text) == ["21", "22", "23", "24", "25", "26", "27", "28"], "chart labels every local calendar day in rolling week")
    check(UsageTrendChartLayout.nearestPointIndex(at: 26, width: 416, count: 84) == 0, "hover at left edge picks oldest point")
    check(UsageTrendChartLayout.nearestPointIndex(at: 408, width: 416, count: 84) == 83, "hover at right edge picks latest point")
    check(abs(UsageTrendChartLayout.yPosition(value: 0, axisMaximum: 60, height: 84) - 63) < 0.01, "zero usage is at graph baseline")
    check(abs(UsageTrendChartLayout.yPosition(value: 60, axisMaximum: 60, height: 84) - 8) < 0.01, "axis maximum is at graph top")
}
