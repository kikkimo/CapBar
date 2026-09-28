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
    let series = UsageTrendCalculator.calculate(samples: samples, intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour))
    let last = Array(series.points.suffix(4))
    check(series.points.count == 84, "rolling week has eighty-four two-hour bins")
    check(near(last[0].usedPercent, 10) && near(last[1].usedPercent, 10), "0-to-4-hour samples interpolate two ten-point bins")
    check(near(last[2].usedPercent, 40), "manual six-hour sample makes a forty-point bin")
    check(near(last[3].usedPercent, 15), "reset computes one hundred minus ninety plus five")
    check(last[3].crossesReset && !last[2].crossesReset, "only reset-crossing bin is dashed")
    check(near(last[3].remainingPercent, 95), "tooltip has post-reset weekly remainder")
    check(series.points.last?.endAt == Date(timeIntervalSince1970: 8 * hour), "chart end uses UTC two-hour grid")

    let high = UsageTrendCalculator.calculate(
        samples: [sample(6, used: 90, reset: 7), sample(8, used: 95, reset: 175)],
        intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(near(high.points.last?.usedPercent, 105), "reset is detected from time even when used percentage increases")
    check(high.axisMaximum == 110, "axis expands past one hundred without clipping")

    let extreme = UsageTrendCalculator.calculate(
        samples: [sample(6, used: 0, reset: 7), sample(8, used: 100, reset: 175)],
        intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(near(extreme.points.last?.usedPercent, 200), "extreme reset segment can consume two hundred points")
    check(extreme.axisMaximum == 200 && extreme.axisTicks == [0, 100, 200], "dynamic axis shows two hundred with three readable ticks")

    let noResetMetadata = UsageTrendCalculator.calculate(
        samples: [sample(6, used: 90, reset: nil), sample(8, used: 5, reset: nil)],
        intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(noResetMetadata.points.last?.usedPercent == nil, "percentage drop without reset time is unknown")

    let gap = UsageTrendCalculator.calculate(
        samples: [sample(0, used: 30, reset: 80), sample(8, used: 50, reset: 80)],
        intervalHours: 4, endingAt: Date(timeIntervalSince1970: 8 * hour)
    )
    check(gap.points.suffix(4).allSatisfy { $0.usedPercent == nil }, "missed four-hour sample leaves a gap rather than zero")

    let peak = UsageTrendCalculator.calculate(
        samples: [sample(0, used: 0, reset: 80), sample(2, used: 54, reset: 80)],
        intervalHours: 4, endingAt: Date(timeIntervalSince1970: 2 * hour)
    )
    check(peak.axisMaximum == 60 && peak.axisTicks == [0, 20, 40, 60], "fifty-four-point peak gets sixty-point four-tick axis")

    let empty = UsageTrendCalculator.calculate(samples: [], intervalHours: 4, endingAt: Date(timeIntervalSince1970: 9 * hour))
    check(empty.points.allSatisfy { $0.usedPercent == nil }, "no history renders missing points without fabricated usage")
    check(empty.points.last?.endAt == Date(timeIntervalSince1970: 8 * hour), "incomplete current bin is not drawn")
}
