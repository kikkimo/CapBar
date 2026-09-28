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
}
