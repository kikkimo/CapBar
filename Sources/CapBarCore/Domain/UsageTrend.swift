import Foundation

struct UsageTrendPoint: Sendable {
    let endAt: Date
    let usedPercent: Double?
    let remainingPercent: Double?
    let crossesReset: Bool
    let isEstimated: Bool
    var planTier: UsagePlanTier? = nil

    var isMissing: Bool { usedPercent == nil }
}

struct UsageTrendSeries: Sendable {
    let points: [UsageTrendPoint]
    let binHours: Int
    let axisMaximum: Double
    let axisTicks: [Double]
    let sampleCount: Int
    var nextSampleAt: Date? = nil
}

enum UsageTrendCalculator {
    private static let epsilon: TimeInterval = 0.000_001

    static func calculate(
        samples: [UsageHistorySample], intervalHours: Int, endingAt now: Date
    ) -> UsageTrendSeries {
        let ordered = samples
            .filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
            .sorted { $0.capturedAt < $1.capturedAt }
        let spans = zip(ordered, ordered.dropFirst()).map {
            Span(first: $0.0, last: $0.1, intervalHours: max(1, intervalHours))
        }
        let binHours = max(2, intervalHours)
        let binSeconds = Double(binHours) * 3_600
        let pointCount = 7 * 24 / binHours
        let gridEnd = floor(now.timeIntervalSince1970 / binSeconds) * binSeconds
        let firstEnd = gridEnd - Double(pointCount - 1) * binSeconds
        let points = (0..<pointCount).map { index in
            let end = firstEnd + Double(index) * binSeconds
            let start = end - binSeconds
            guard let usage = consumption(from: start, to: end, spans: spans) else {
                return UsageTrendPoint(
                    endAt: Date(timeIntervalSince1970: end), usedPercent: nil,
                    remainingPercent: nil, crossesReset: false, isEstimated: false
                )
            }
            let estimated = !containsSample(at: start, in: ordered) || !containsSample(at: end, in: ordered)
            return UsageTrendPoint(
                endAt: Date(timeIntervalSince1970: end),
                usedPercent: max(0, usage.amount),
                remainingPercent: remaining(at: end, samples: ordered, spans: spans),
                crossesReset: usage.crossesReset,
                isEstimated: estimated,
                planTier: usage.planTier
            )
        }
        let maximum = max(10, ceil((points.compactMap(\.usedPercent).max() ?? 0) / 10) * 10)
        let ticks = Int(maximum) % 30 == 0
            ? [0, maximum / 3, maximum * 2 / 3, maximum]
            : [0, maximum / 2, maximum]
        let sampleCount = ordered.filter {
            $0.capturedAt >= now.addingTimeInterval(-7 * 86_400) && $0.capturedAt <= now
        }.count
        return UsageTrendSeries(points: points, binHours: binHours, axisMaximum: maximum, axisTicks: ticks, sampleCount: sampleCount)
    }

    private static func consumption(
        from start: TimeInterval, to end: TimeInterval, spans: [Span]
    ) -> (amount: Double, crossesReset: Bool, planTier: UsagePlanTier?)? {
        var cursor = start
        var amount = 0.0
        var crossesReset = false
        var planTier: UsagePlanTier?
        var hasSpan = false
        while cursor < end - epsilon {
            guard let span = spans.first(where: {
                $0.start <= cursor + epsilon && $0.end > cursor + epsilon
            }), span.isValid else { return nil }
            if hasSpan && span.first.planTier != planTier { return nil }
            planTier = span.first.planTier
            hasSpan = true
            let stop = min(end, span.end)
            amount += span.unwrapped(at: stop) - span.unwrapped(at: cursor)
            if let reset = span.reset, reset > cursor + epsilon, reset <= stop + epsilon {
                crossesReset = true
            }
            cursor = stop
        }
        return (amount, crossesReset, planTier)
    }

    private static func containsSample(at time: TimeInterval, in samples: [UsageHistorySample]) -> Bool {
        samples.contains { abs($0.capturedAt.timeIntervalSince1970 - time) < epsilon }
    }

    private static func remaining(
        at time: TimeInterval, samples: [UsageHistorySample], spans: [Span]
    ) -> Double? {
        if let exact = samples.first(where: { abs($0.capturedAt.timeIntervalSince1970 - time) < epsilon }) {
            return 100 - exact.usedPercent
        }
        guard let span = spans.first(where: { $0.start < time && time < $0.end && $0.isValid }) else {
            return nil
        }
        return 100 - span.used(at: time)
    }

    private struct Span {
        let first: UsageHistorySample
        let last: UsageHistorySample
        let start: TimeInterval
        let end: TimeInterval
        let reset: TimeInterval?
        let isValid: Bool

        init(first: UsageHistorySample, last: UsageHistorySample, intervalHours: Int) {
            self.first = first
            self.last = last
            let startTime = first.capturedAt.timeIntervalSince1970
            let endTime = last.capturedAt.timeIntervalSince1970
            start = startTime
            end = endTime
            let oldReset = first.resetsAt?.timeIntervalSince1970
            let newReset = last.resetsAt?.timeIntervalSince1970
            if let oldReset, let newReset,
               oldReset > startTime, oldReset <= endTime, newReset > oldReset {
                reset = oldReset
            } else {
                reset = nil
            }
            let isNearReset = oldReset.map {
                startTime >= $0 - Double(intervalHours) * 3_600 && startTime <= $0
            } ?? false
            let allowedHours = isNearReset ? min(intervalHours, 2) : intervalHours
            isValid = endTime > startTime && endTime - startTime <= Double(allowedHours) * 3_600 + 15 * 60
                && first.planTier == last.planTier
                && (reset != nil || last.usedPercent >= first.usedPercent)
        }

        func unwrapped(at time: TimeInterval) -> Double {
            guard let reset else {
                return first.usedPercent + (last.usedPercent - first.usedPercent) * (time - start) / (end - start)
            }
            if time >= end { return 100 + last.usedPercent }
            if time <= reset {
                return first.usedPercent + (100 - first.usedPercent) * (time - start) / (reset - start)
            }
            return 100 + last.usedPercent * (time - reset) / (end - reset)
        }

        func used(at time: TimeInterval) -> Double {
            guard let reset else { return unwrapped(at: time) }
            if time >= end { return last.usedPercent }
            if time < reset { return unwrapped(at: time) }
            if time == reset { return 0 }
            return last.usedPercent * (time - reset) / (end - reset)
        }
    }
}
