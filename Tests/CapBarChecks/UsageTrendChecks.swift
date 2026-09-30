import Foundation
@testable import CapBarCore

@MainActor func runUsageTrendChecks() {
    let hour: TimeInterval = 3_600
    func sample(_ at: Double, used: Double, reset: Double?) -> UsageHistorySample {
        UsageHistorySample(
            capturedAt: Date(timeIntervalSince1970: at * hour),
            usedPercent: used,
            resetsAt: reset.map { Date(timeIntervalSince1970: $0 * hour) }
        )
    }
    func near(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 0.000_001
    }

    let samples = [
        sample(0, used: 30, reset: 7),
        sample(4, used: 50, reset: 7),
        sample(6, used: 90, reset: 7),
        sample(8, used: 5, reset: 175)
    ]
    let twoHourSamples = [samples[0], sample(2, used: 40, reset: 7)] + samples.dropFirst()
    let series = UsageTrendCalculator.calculate(samples: twoHourSamples, intervalHours: 2, endingAt: Date(timeIntervalSince1970: 8 * hour))
    let last = Array(series.points.suffix(4))
    check(series.points.count == 84, "rolling week has eighty-four two-hour bins")
    check(series.sampleCount == 5, "trend reports real samples within the rolling seven days")
    check(near(last[0].usedPercent, 10) && near(last[1].usedPercent, 10), "two adjacent two-hour intervals each consume ten points")
    check(near(last[2].usedPercent, 40), "six-hour sample makes a forty-point bin")
    check(near(last[3].usedPercent, 15), "reset computes one hundred minus ninety plus five")
    check(last[3].crossesReset && !last[2].crossesReset, "only reset-crossing bin is dashed")
    check(near(last[3].remainingPercent, 95), "tooltip has post-reset weekly remainder")
    check(series.points.last?.endAt == Date(timeIntervalSince1970: 8 * hour), "chart end uses UTC two-hour grid")
    let withOldSample = UsageTrendCalculator.calculate(
        samples: [sample(-169, used: 10, reset: 7)] + twoHourSamples,
        intervalHours: 2, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(withOldSample.sampleCount == 5, "sample count excludes records older than the rolling seven days")

    let high = UsageTrendCalculator.calculate(
        samples: [sample(6, used: 90, reset: 7), sample(8, used: 95, reset: 175)],
        intervalHours: 2, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(near(high.points.last?.usedPercent, 105), "reset is detected from time even when used percentage increases")
    check(high.axisMaximum == 110, "axis expands past one hundred without clipping")

    let extreme = UsageTrendCalculator.calculate(
        samples: [sample(6, used: 0, reset: 7), sample(8, used: 100, reset: 175)],
        intervalHours: 2, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(near(extreme.points.last?.usedPercent, 200), "extreme reset segment can consume two hundred points")
    check(extreme.axisMaximum == 200 && extreme.axisTicks == [0, 100, 200], "dynamic axis shows two hundred with three readable ticks")

    let noResetMetadata = UsageTrendCalculator.calculate(
        samples: [sample(6, used: 90, reset: nil), sample(8, used: 5, reset: nil)],
        intervalHours: 2, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(noResetMetadata.points.last?.usedPercent == nil, "percentage drop without reset time is unknown")

    let gap = UsageTrendCalculator.calculate(
        samples: [sample(0, used: 30, reset: 80), sample(8, used: 50, reset: 80)],
        intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(gap.points.suffix(4).allSatisfy { $0.usedPercent == nil }, "missed four-hour sample leaves a gap rather than zero")

    let peak = UsageTrendCalculator.calculate(
        samples: [sample(0, used: 0, reset: 80), sample(2, used: 54, reset: 80)],
        intervalHours: 2, endingAt: Date(timeIntervalSince1970: 2 * hour)
    )
    check(peak.axisMaximum == 60 && peak.axisTicks == [0, 20, 40, 60], "fifty-four-point peak gets sixty-point four-tick axis")

    let empty = UsageTrendCalculator.calculate(samples: [], intervalHours: 4, endingAt: Date(timeIntervalSince1970: 9 * hour))
    check(empty.sampleCount == 0, "empty trend reports zero recorded samples")
    check(empty.points.allSatisfy { $0.usedPercent == nil }, "no history renders missing points without fabricated usage")
    check(empty.points.last?.endAt == Date(timeIntervalSince1970: 8 * hour), "incomplete current bin is not drawn")

    let expectedGrids: [(setting: Int, count: Int, lastHour: Double)] = [
        (1, 84, 10), (2, 84, 10), (3, 56, 9),
        (4, 42, 8), (6, 28, 6), (8, 21, 8)
    ]
    for grid in expectedGrids {
        let trend = UsageTrendCalculator.calculate(
            samples: [], intervalHours: grid.setting,
            endingAt: Date(timeIntervalSince1970: 10.5 * hour)
        )
        check(trend.points.count == grid.count && trend.points.last?.endAt == Date(timeIntervalSince1970: grid.lastHour * hour),
              "setting \(grid.setting) uses its UTC-aligned display grid with a two-hour minimum")
    }
    for interval in [3, 4, 6, 8] {
        let trend = UsageTrendCalculator.calculate(
            samples: [sample(0, used: 10, reset: 80), sample(Double(interval), used: 40, reset: 80)],
            intervalHours: interval, endingAt: Date(timeIntervalSince1970: Double(interval) * hour)
        )
        check(near(trend.points.last?.usedPercent, 30),
              "setting \(interval) draws consumption over one complete interval")
    }
    let fourHour = UsageTrendCalculator.calculate(
        samples: samples, intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(fourHour.points.count == 42 && near(fourHour.points[40].usedPercent, 20)
          && near(fourHour.points[41].usedPercent, 55),
          "four-hour chart aggregates 0–4 and 4–8, including manual six-hour sample and reset")
    check(fourHour.points.last?.crossesReset == true, "four-hour bin records a reset inside the interval")

    let hourly = UsageTrendCalculator.calculate(
        samples: [sample(0, used: 10, reset: 80), sample(1, used: 20, reset: 80), sample(2, used: 50, reset: 80)],
        intervalHours: 1, endingAt: Date(timeIntervalSince1970: 2 * hour)
    )
    check(near(hourly.points.last?.usedPercent, 40), "one-hour sampling produces one two-hour usage point")
    let manualBridge = UsageTrendCalculator.calculate(
        samples: [sample(0, used: 10, reset: 80), sample(2, used: 30, reset: 80),
                  sample(4, used: 50, reset: 80), sample(6, used: 70, reset: 80)],
        intervalHours: 3, endingAt: Date(timeIntervalSince1970: 6 * hour)
    )
    check(near(manualBridge.points[54].usedPercent, 30) && near(manualBridge.points[55].usedPercent, 30),
          "manual samples between three-hour grid points bridge a missed regular sample")
    let stableTier = UsageTrendCalculator.calculate(samples: [
        UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 0), usedPercent: 10,
                           resetsAt: Date(timeIntervalSince1970: 80 * hour), planTier: .claudePro),
        UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 2 * hour), usedPercent: 30,
                           resetsAt: Date(timeIntervalSince1970: 80 * hour), planTier: .claudePro)
    ], intervalHours: 2, endingAt: Date(timeIntervalSince1970: 2 * hour))
    check(stableTier.points.last?.planTier == .claudePro && near(stableTier.points.last?.usedPercent, 20),
          "a measured interval carries its historical subscription tier")
    let changedTier = UsageTrendCalculator.calculate(samples: [
        UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 0), usedPercent: 10,
                           resetsAt: Date(timeIntervalSince1970: 80 * hour), planTier: .claudePro),
        UsageHistorySample(capturedAt: Date(timeIntervalSince1970: 2 * hour), usedPercent: 30,
                           resetsAt: Date(timeIntervalSince1970: 80 * hour), planTier: .claudeMax5)
    ], intervalHours: 2, endingAt: Date(timeIntervalSince1970: 2 * hour))
    check(changedTier.points.last?.usedPercent == nil,
          "an interval crossing a subscription change is left blank instead of interpolated")

    func trend(_ values: [Double?], hours: [Double] = [2, 4, 6]) -> UsageTrendSeries {
        UsageTrendSeries(
            points: zip(hours, values).map { end, value in
                UsageTrendPoint(endAt: Date(timeIntervalSince1970: end * hour), usedPercent: value,
                                remainingPercent: nil, crossesReset: false, isEstimated: false)
            },
            binHours: 2, axisMaximum: 10, axisTicks: [0, 5, 10], sampleCount: 3
        )
    }
    let pro = trend([2, 3, 4])
    let maxFive = trend([1, nil, 2])
    let summed = UsageTrendAggregator.aggregate(
        [WeightedUsageTrend(series: pro, capacity: 1), WeightedUsageTrend(series: maxFive, capacity: 5)],
        baselineCapacity: 1
    )
    check(near(summed?.points[0].usedPercent, 7) && summed?.points[1].usedPercent == nil
          && near(summed?.points[2].usedPercent, 14),
          "total converts plan capacities before summing and leaves incomplete bins blank")
    check(summed?.axisMaximum == 20 && summed?.axisTicks == [0, 10, 20],
          "total axis expands to the weighted observed peak")
    let maxBased = UsageTrendAggregator.aggregate(
        [WeightedUsageTrend(series: maxFive, capacity: 5), WeightedUsageTrend(series: pro, capacity: 1)],
        baselineCapacity: 5
    )
    check(near(maxBased?.points[0].usedPercent, 1.4),
          "first account capacity changes the total display unit")
    let upgraded = UsageTrendSeries(points: maxFive.points.enumerated().map { index, point in
        UsageTrendPoint(endAt: point.endAt, usedPercent: point.usedPercent, remainingPercent: nil,
                        crossesReset: false, isEstimated: false,
                        planTier: index == 2 ? .claudeMax20 : .claudeMax5)
    }, binHours: 2, axisMaximum: 10, axisTicks: [0, 5, 10], sampleCount: 3)
    let upgradedTotal = UsageTrendAggregator.aggregate(
        [WeightedUsageTrend(series: pro, capacity: 1), WeightedUsageTrend(series: upgraded, capacity: 5)],
        baselineCapacity: 1
    )
    check(near(upgradedTotal?.points[0].usedPercent, 7)
          && near(upgradedTotal?.points[2].usedPercent, 44),
          "historical tier weights a past bin with its captured capacity, not today's tier")
    let upgradedBreakdown = ProviderTrendOverview.build([
        TrendOverviewAccount(label: "Pro", tier: .claudePro, series: pro),
        TrendOverviewAccount(label: "Upgraded", tier: .claudeMax5, series: upgraded)
    ]).contributions(at: pro.points[2].endAt)
    check(near(upgradedBreakdown?[1].equivalentPercent, 40),
          "tooltip contribution uses the historical tier behind the plotted total")
    let mismatched = trend([1, 2, 3], hours: [2, 5, 6])
    let mismatchedTotal = UsageTrendAggregator.aggregate(
        [WeightedUsageTrend(series: pro, capacity: 1), WeightedUsageTrend(series: mismatched, capacity: 1)],
        baselineCapacity: 1
    )
    check(mismatchedTotal?.points[1].usedPercent == nil,
          "samples with different UTC interval ends cannot be combined by array position")
    check(UsageTrendAggregator.aggregate([WeightedUsageTrend(series: pro, capacity: 0)], baselineCapacity: 1) == nil,
          "unknown or invalid capacity does not create a misleading total")

    let sharedClaudeRange = UsageTrendColorScale.range(for: [pro, maxFive])
    let codexRange = UsageTrendColorScale.range(for: [trend([10, 20, 30])])
    check(sharedClaudeRange?.lowerBound == 1 && sharedClaudeRange?.upperBound == 4,
          "all Claude account charts use one observed color range")
    check(codexRange?.lowerBound == 10 && codexRange?.upperBound == 30,
          "Codex account colors are independent from Claude")
    check(UsageTrendColorScale.range(for: [summed!])?.lowerBound == 7
          && UsageTrendColorScale.range(for: [summed!])?.upperBound == 14,
          "a total chart maps its own observed minimum and maximum")
    check(UsageTrendColorScale.fraction(1, in: sharedClaudeRange) == 0
          && UsageTrendColorScale.fraction(4, in: sharedClaudeRange) == 1,
          "observed bounds reach both ends of the palette instead of using zero and axis maximum")
    check(UsageTrendColorScale.fraction(3, in: 3...3) == 0.5
          && UsageTrendColorScale.range(for: [trend([nil, nil, nil])]) == nil,
          "flat or missing history gets a neutral color without a divide-by-zero")

    check(UsagePlanTier.detect(provider: .claude, rawPlan: "Pro") == .claudePro
          && UsagePlanTier.detect(provider: .claude, rawPlan: "Max 20x") == .claudeMax20,
          "explicit Claude plan tiers can be recognized without credentials")
    check(UsagePlanTier.detect(provider: .codex, rawPlan: "Plus") == .codexPlus
          && UsagePlanTier.detect(provider: .codex, rawPlan: "Pro 5x") == .codexPro5,
          "explicit Codex plan tiers map only within Codex")
    check(UsagePlanTier.detect(provider: .claude, rawPlan: "team") == nil
          && UsagePlanTier.detect(provider: .claude, rawPlan: "max") == nil
          && UsagePlanTier.detect(provider: .codex, rawPlan: "pro") == nil,
          "ambiguous plan names never silently select a subscription multiplier")
    check(UsagePlanTier.claudePro.capacityFactor == 1
          && UsagePlanTier.claudeMax5.capacityFactor == 5
          && UsagePlanTier.claudeMax20.capacityFactor == 20
          && UsagePlanTier.claudeTeamStandard.capacityFactor == 1.25
          && UsagePlanTier.claudeTeamPremium.capacityFactor == 6.25
          && UsagePlanTier.codexPlus.capacityFactor == 1
          && UsagePlanTier.codexPro5.capacityFactor == 5
          && UsagePlanTier.codexPro20.capacityFactor == 20,
          "candidate proposal factors convert each tier to provider base capacity")

    let overview = ProviderTrendOverview.build([
        TrendOverviewAccount(label: "Pro account", tier: .claudePro, series: pro),
        TrendOverviewAccount(label: "Max account", tier: .claudeMax5, series: maxFive)
    ])
    check(overview.accountCount == 2 && overview.baselinePlan == .claudePro
          && near(overview.series?.points[0].usedPercent, 7),
          "provider overview uses the first account plan as its display unit")
    let breakdown = overview.contributions(at: pro.points[0].endAt)
    check(breakdown?.map(\.label) == ["Pro account", "Max account"]
          && near(breakdown?[0].equivalentPercent, 2)
          && near(breakdown?[1].equivalentPercent, 5)
          && near(breakdown?.reduce(0) { $0 + $1.equivalentPercent }, 7),
          "total tooltip breaks down each account in the same baseline units as its plotted total")
    check(overview.contributions(at: pro.points[1].endAt) == nil,
          "total tooltip does not invent account values for an incomplete interval")
    let unknownOverview = ProviderTrendOverview.build([
        TrendOverviewAccount(tier: .claudePro, series: pro),
        TrendOverviewAccount(tier: nil, series: maxFive)
    ])
    check(unknownOverview.uncalibratedCount == 1 && unknownOverview.series == nil,
          "one unknown subscription blocks a misleading partial total")
    let pendingOverview = ProviderTrendOverview.build([
        TrendOverviewAccount(tier: .claudePro, series: pro),
        TrendOverviewAccount(tier: .claudeMax5, series: nil)
    ])
    check(pendingOverview.pendingHistoryCount == 1 && pendingOverview.series == nil,
          "a missing account trend waits for history instead of treating it as zero")
}
