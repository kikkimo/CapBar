import Foundation
@testable import CapBarCore

@MainActor func runProviderTrendStatisticsChecks() {
    let hour: TimeInterval = 3_600
    let end = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func series(_ values: [Double?], binHours: Int = 2, endingAt end: Date = end) -> UsageTrendSeries {
        let points = values.enumerated().map { index, value in
            UsageTrendPoint(
                endAt: end.addingTimeInterval(Double(index - values.count + 1) * Double(binHours) * hour),
                usedPercent: value, remainingPercent: nil, crossesReset: false, isEstimated: false
            )
        }
        return UsageTrendSeries(points: points, binHours: binHours, axisMaximum: 20,
                                axisTicks: [0, 10, 20], sampleCount: values.count)
    }
    func single(_ values: [Double?], binHours: Int = 2, endingAt end: Date = end) -> ProviderTrendOverview {
        ProviderTrendOverview.build([
            TrendOverviewAccount(label: "alpha@example.com", tier: .claudePro,
                                 series: series(values, binHours: binHours, endingAt: end))
        ])
    }
    func near(_ actual: Double?, _ expected: Double) -> Bool {
        actual.map { abs($0 - expected) < 0.000_001 } ?? false
    }

    let sparse = single([nil, 0, 2, 4, nil]).statistics(calendar: calendar)
    let trailingGap = single([1, 4, nil])
    check(near(trailingGap.latestObservedPoint?.usedPercent, 4)
          && trailingGap.latestObservedPoint?.endAt == end.addingTimeInterval(-2 * hour),
          "total headline uses the preceding observed interval while the newest bin awaits a sample")
    check(single([0, nil]).latestObservedPoint?.usedPercent == 0,
          "a measured zero remains available when the latest bin is missing")
    check(single([nil, nil]).latestObservedPoint == nil,
          "total headline remains unavailable when no interval has been observed")
    let partiallyObservedTotal = ProviderTrendOverview.build([
        TrendOverviewAccount(label: "one@example.com", tier: .claudePro, series: series([2, 4, 6])),
        TrendOverviewAccount(label: "two@example.com", tier: .claudePro, series: series([1, 3, nil]))
    ])
    check(near(partiallyObservedTotal.latestObservedPoint?.usedPercent, 6)
          && partiallyObservedTotal.latestObservedPoint?.endAt == end,
          "total headline includes the latest observed usage even when another account is missing")
    check(near(sparse?.peak?.value, 4) && sparse?.peak?.endAt == end.addingTimeInterval(-2 * hour),
          "peak uses the largest observed interval and its ending time")
    check(near(sparse?.minimum, 0) && near(sparse?.average, 2) && near(sparse?.observedTotal, 6),
          "minimum includes real zero while average and total exclude missing intervals")
    check(sparse?.validBinCount == 3 && sparse?.expectedBinCount == 5,
          "coverage reports valid intervals against every plotted interval")
    check(near(sparse?.recent24Hours.usedPercent, 6)
          && sparse?.recent24Hours.validBinCount == 3
          && sparse?.recent24Hours.expectedBinCount == 12
          && sparse?.changePercent == nil,
          "partial recent day keeps its observed amount and coverage without inventing a comparison")

    let allMissing = single([nil, nil]).statistics(calendar: calendar)
    check(allMissing?.peak == nil && allMissing?.minimum == nil && allMissing?.average == nil
          && allMissing?.observedTotal == nil && allMissing?.leader == nil,
          "no measured intervals display unavailable statistics instead of zero")
    let idle = single([0, 0]).statistics(calendar: calendar)
    check(near(idle?.average, 0) && near(idle?.observedTotal, 0) && idle?.leader == nil,
          "genuine zero use is measured but does not invent a leading account")

    let weighted = ProviderTrendOverview.build([
        TrendOverviewAccount(label: "Pro account", tier: .claudePro, series: series([1, 2, nil])),
        TrendOverviewAccount(label: "Max account", tier: .claudeMax5, series: series([2, 1, 3]))
    ]).statistics(calendar: calendar)
    check(near(weighted?.observedTotal, 33) && weighted?.validBinCount == 3,
          "provider statistics include every bin with at least one observed account")
    check(weighted?.leader?.label == "Max account"
          && near(weighted?.leader?.equivalentPercent, 30)
          && near(weighted?.leader?.sharePercent, 30 / 33 * 100),
          "leader sums each account's observed equivalent usage across changing participation")

    let twoDays = single(Array(repeating: 1.0, count: 12) + Array(repeating: 2.0, count: 12))
        .statistics(calendar: calendar)
    check(near(twoDays?.recent24Hours.usedPercent, 24)
          && twoDays?.recent24Hours.validBinCount == 12
          && near(twoDays?.changePercent, 100),
          "two complete twenty-four-hour windows show relative change")
    let missingPrevious = single([nil] + Array(repeating: 1.0, count: 11)
                                 + Array(repeating: 2.0, count: 12)).statistics(calendar: calendar)
    check(near(missingPrevious?.recent24Hours.usedPercent, 24)
          && missingPrevious?.changePercent == nil,
          "comparison is unavailable if the prior day contains a gap")
    let zeroBaseline = single(Array(repeating: 0.0, count: 12)
                              + Array(repeating: 2.0, count: 12)).statistics(calendar: calendar)
    check(zeroBaseline?.changePercent == nil,
          "positive use after a zero baseline does not produce an infinite percent change")
    let idleComparison = single(Array(repeating: 0.0, count: 24)).statistics(calendar: calendar)
    check(near(idleComparison?.changePercent, 0), "two fully observed idle days have zero change")

    let localStart = ISO8601DateFormatter().date(from: "2026-09-27T16:00:00Z")!
    let eveningValues = (0..<24).map { index -> Double in
        [18, 20, 22].contains(index * 2 % 24) ? 8 : 1
    }
    let evenings = single(eveningValues, endingAt: localStart.addingTimeInterval(48 * hour))
        .statistics(calendar: calendar)
    check(evenings?.highUsagePeriod?.label == "18:00–24:00",
          "high-use period follows local clock time across multiple observed days")
    check(evenings?.lowUsagePeriod?.label == "00:00–06:00",
          "low-use period picks the lowest observed local-time rate, including genuine quiet hours")
    let coarseValues: [Double] = [1, 1, 16, 1, 1, 16]
    let coarse = single(coarseValues, binHours: 8, endingAt: localStart.addingTimeInterval(48 * hour))
        .statistics(calendar: calendar)
    check(coarse?.highUsagePeriod?.label == "16:00–24:00",
          "eight-hour data uses broad eight-hour local periods rather than six-hour precision")
    check(coarse?.lowUsagePeriod?.label == "00:00–08:00",
          "low-use period respects the same broad buckets as high use")
    let uniform = single(Array(repeating: 1.0, count: 24),
                         endingAt: localStart.addingTimeInterval(48 * hour)).statistics(calendar: calendar)
    check(uniform?.highUsagePeriod == nil && uniform?.lowUsagePeriod == nil
          && uniform?.usagePeriodsAreUniform == true,
          "equal use throughout the day does not invent a high or low period")
    let oneObservedPeriod = single([8, nil, nil, 8, nil, nil, 8], binHours: 8,
                                   endingAt: localStart.addingTimeInterval(56 * hour))
        .statistics(calendar: calendar)
    check(oneObservedPeriod?.highUsagePeriod == nil && oneObservedPeriod?.lowUsagePeriod == nil
          && oneObservedPeriod?.usagePeriodsAreUniform == false,
          "one observed time bucket cannot establish a high, low, or uniform daily pattern")
    check(sparse?.highUsagePeriod == nil && sparse?.lowUsagePeriod == nil
          && sparse?.usagePeriodsAreUniform == false,
          "a few isolated bins do not claim habitual high or low periods")
}
