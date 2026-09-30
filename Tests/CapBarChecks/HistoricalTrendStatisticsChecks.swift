import Foundation
@testable import CapBarCore

@MainActor func runHistoricalTrendStatisticsChecks() {
    let hour: TimeInterval = 3_600
    let day: TimeInterval = 24 * hour
    let origin = Date(timeIntervalSince1970: 0)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!

    func series(days: Int, missing: Set<Int> = []) -> UsageTrendSeries {
        let points = (0..<(days * 6)).map { index -> UsageTrendPoint in
            let dayIndex = index / 6
            let endAt = origin.addingTimeInterval(Double(index + 1) * 4 * hour)
            return UsageTrendPoint(endAt: endAt,
                                   usedPercent: missing.contains(index) ? nil : Double(dayIndex + 1),
                                   remainingPercent: nil, crossesReset: false, isEstimated: false)
        }
        return UsageTrendSeries(points: points, binHours: 4, axisMaximum: 10,
                                axisTicks: [0, 5, 10], sampleCount: points.count)
    }
    func near(_ actual: Double?, _ expected: Double) -> Bool {
        actual.map { abs($0 - expected) < 0.000_001 } ?? false
    }

    let nineDays = HistoricalTrendStatistics.calculate(series: series(days: 9), calendar: utc)
    check(near(nineDays.highSevenDays?.usedPercent, 252)
          && nineDays.highSevenDays?.startsAt == origin.addingTimeInterval(2 * day)
          && nineDays.highSevenDays?.endsAt == origin.addingTimeInterval(9 * day),
          "highest seven days use the greatest complete rolling day window")
    check(near(nineDays.lowSevenDays?.usedPercent, 168)
          && nineDays.lowSevenDays?.startsAt == origin
          && nineDays.lowSevenDays?.endsAt == origin.addingTimeInterval(7 * day),
          "lowest seven days include the first complete rolling day window")
    check(near(nineDays.highDay?.usedPercent, 54)
          && nineDays.highDay?.startsAt == origin.addingTimeInterval(8 * day),
          "highest day reports its complete local calendar day and use")
    check(near(nineDays.highInterval?.usedPercent, 9)
          && nineDays.highInterval?.endsAt == origin.addingTimeInterval(9 * day),
          "highest interval reports the actual observed bin, including its time")

    let sevenDays = HistoricalTrendStatistics.calculate(series: series(days: 7), calendar: utc)
    check(near(sevenDays.highSevenDays?.usedPercent, 168)
          && near(sevenDays.lowSevenDays?.usedPercent, 168),
          "exactly seven complete days form one valid rolling window")
    let missingBin = HistoricalTrendStatistics.calculate(series: series(days: 9, missing: [4 * 6 + 2]), calendar: utc)
    check(missingBin.highSevenDays == nil && missingBin.lowSevenDays == nil,
          "a missing bin invalidates every seven-day window that crosses it")
    check(near(missingBin.highDay?.usedPercent, 54)
          && near(missingBin.highInterval?.usedPercent, 9),
          "an incomplete week does not hide complete-day and valid-interval records")
    let partial = HistoricalTrendStatistics.calculate(series: series(days: 1, missing: [0]), calendar: utc)
    check(partial.highSevenDays == nil && partial.highDay == nil
          && near(partial.highInterval?.usedPercent, 1),
          "partial day has no day or week record but retains observed interval use")
    let empty = HistoricalTrendStatistics.calculate(series: series(days: 0), calendar: utc)
    check(empty.highSevenDays == nil && empty.lowSevenDays == nil
          && empty.highDay == nil && empty.highInterval == nil,
          "empty history has no invented zero-use records")
    let idlePoints = series(days: 7).points.map {
        UsageTrendPoint(endAt: $0.endAt, usedPercent: 0, remainingPercent: nil,
                        crossesReset: false, isEstimated: false)
    }
    let idleSeries = UsageTrendSeries(points: idlePoints, binHours: 4,
                                      axisMaximum: 10, axisTicks: [0, 5, 10], sampleCount: idlePoints.count)
    let idle = HistoricalTrendStatistics.calculate(series: idleSeries, calendar: utc)
    check(near(idle.highSevenDays?.usedPercent, 0) && near(idle.lowSevenDays?.usedPercent, 0)
          && near(idle.highDay?.usedPercent, 0) && near(idle.highInterval?.usedPercent, 0),
          "fully observed zero use is a real historical record, distinct from missing data")

    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let local = HistoricalTrendStatistics.calculate(series: series(days: 9), calendar: shanghai)
    check(near(local.highDay?.usedPercent, 52)
          && local.highDay?.startsAt == origin.addingTimeInterval(8 * day - 8 * hour),
          "daily totals split UTC bins at local midnight")

    var pacific = Calendar(identifier: .gregorian)
    pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let springStart = ISO8601DateFormatter().date(from: "2026-03-06T00:00:00Z")!
    let springPoints = (1...(10 * 6)).map { index in
        UsageTrendPoint(endAt: springStart.addingTimeInterval(Double(index) * 4 * hour),
                        usedPercent: 1, remainingPercent: nil, crossesReset: false, isEstimated: false)
    }
    let springSeries = UsageTrendSeries(points: springPoints, binHours: 4,
                                        axisMaximum: 10, axisTicks: [0, 5, 10], sampleCount: springPoints.count)
    let spring = HistoricalTrendStatistics.calculate(series: springSeries, calendar: pacific)
    check(near(spring.highSevenDays?.usedPercent, 41.75),
          "rolling local days include a 23-hour daylight-saving day without treating it as a gap")
}
