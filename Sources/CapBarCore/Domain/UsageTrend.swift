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
        let spans = ordered.dropLast().enumerated().map { index, first in
            Span(first: first, last: ordered[index + 1], prior: index > 0 ? ordered[index - 1] : nil,
                 intervalHours: max(1, intervalHours))
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

    // Walk adjacent sample spans once. The seven-day chart can scan its small window;
    // an all-time history must not repeat a scan of every sample for every bin.
    static func calculateHistory(
        samples: [UsageHistorySample], intervalHours: Int, endingAt now: Date
    ) -> UsageTrendSeries {
        let ordered = samples
            .filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        let binHours = max(2, intervalHours)
        let binSeconds = Double(binHours) * 3_600
        guard let first = ordered.first, let last = ordered.last else {
            return UsageTrendSeries(points: [], binHours: binHours, axisMaximum: 10,
                                    axisTicks: [0, 5, 10], sampleCount: 0)
        }
        let firstEnd = floor(first.capturedAt.timeIntervalSince1970 / binSeconds) * binSeconds + binSeconds
        let lastEnd = floor(last.capturedAt.timeIntervalSince1970 / binSeconds) * binSeconds
        let spanSeconds = lastEnd - firstEnd
        guard spanSeconds >= 0, spanSeconds <= 1_000_000 * binSeconds else {
            return UsageTrendSeries(points: [], binHours: binHours, axisMaximum: 10,
                                    axisTicks: [0, 5, 10], sampleCount: ordered.count)
        }
        let spans = ordered.dropLast().enumerated().map { index, first in
            Span(first: first, last: ordered[index + 1], prior: index > 0 ? ordered[index - 1] : nil,
                 intervalHours: max(1, intervalHours))
        }
        var spanIndex = 0
        let pointCount = Int(spanSeconds / binSeconds) + 1
        var points: [UsageTrendPoint] = []
        points.reserveCapacity(pointCount)
        var maximumUsage = 0.0
        for index in 0..<pointCount {
            let end = firstEnd + Double(index) * binSeconds
            var cursor = end - binSeconds
            var amount = 0.0
            var crossesReset = false
            var tier: UsagePlanTier?
            var hasSpan = false
            var valid = true
            while cursor < end - epsilon {
                while spanIndex < spans.count && spans[spanIndex].end <= cursor + epsilon {
                    spanIndex += 1
                }
                guard spanIndex < spans.count else { valid = false; break }
                let span = spans[spanIndex]
                guard span.start <= cursor + epsilon, span.isValid else { valid = false; break }
                if let current = tier, let observed = span.observedPlanTier, current != observed {
                    valid = false
                    break
                }
                tier = tier ?? span.observedPlanTier
                hasSpan = true
                let stop = min(end, span.end)
                amount += span.unwrapped(at: stop) - span.unwrapped(at: cursor)
                if let reset = span.reset, reset > cursor + epsilon, reset <= stop + epsilon {
                    crossesReset = true
                }
                cursor = stop
            }
            let value = valid && hasSpan ? max(0, amount) : nil
            if let value { maximumUsage = max(maximumUsage, value) }
            points.append(UsageTrendPoint(endAt: Date(timeIntervalSince1970: end),
                                          usedPercent: value, remainingPercent: nil,
                                          crossesReset: valid && crossesReset, isEstimated: false,
                                          planTier: valid ? tier : nil))
        }
        let maximum = max(10, ceil(maximumUsage / 10) * 10)
        let ticks = Int(maximum) % 30 == 0
            ? [0, maximum / 3, maximum * 2 / 3, maximum]
            : [0, maximum / 2, maximum]
        return UsageTrendSeries(points: points, binHours: binHours, axisMaximum: maximum,
                                axisTicks: ticks, sampleCount: ordered.count)
    }

    private static func consumption(
        from start: TimeInterval, to end: TimeInterval, spans: [Span]
    ) -> (amount: Double, crossesReset: Bool, planTier: UsagePlanTier?)? {
        var cursor = start
        var amount = 0.0
        var crossesReset = false
        var planTier: UsagePlanTier?
        while cursor < end - epsilon {
            guard let span = spans.first(where: {
                $0.start <= cursor + epsilon && $0.end > cursor + epsilon
            }), span.isValid else { return nil }
            if let current = planTier, let observed = span.observedPlanTier, current != observed { return nil }
            planTier = planTier ?? span.observedPlanTier
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
        let oldCycleTail: Double
        let isValid: Bool
        var observedPlanTier: UsagePlanTier? { first.planTier ?? last.planTier }

        init(first: UsageHistorySample, last: UsageHistorySample, prior: UsageHistorySample?, intervalHours: Int) {
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
            if let reset, let prior,
               reset - startTime <= 10 * 60, endTime - reset <= 10 * 60,
               prior.resetsAt == first.resetsAt,
               prior.usedPercent <= first.usedPercent,
               first.capturedAt.timeIntervalSince(prior.capturedAt) > 0,
               first.capturedAt.timeIntervalSince(prior.capturedAt) <= Double(intervalHours) * 3_600 + 15 * 60,
               prior.planTier == nil || first.planTier == nil || prior.planTier == first.planTier {
                let observedRate = (first.usedPercent - prior.usedPercent) /
                    first.capturedAt.timeIntervalSince(prior.capturedAt)
                let projected = first.usedPercent + observedRate * (reset - startTime)
                oldCycleTail = projected >= 100 ? max(0, 100 - first.usedPercent) : 0
            } else {
                oldCycleTail = 0
            }
            let isNearReset = oldReset.map {
                startTime >= $0 - Double(intervalHours) * 3_600 && startTime <= $0
            } ?? false
            let allowedHours = isNearReset ? min(intervalHours, 2) : intervalHours
            isValid = endTime > startTime && endTime - startTime <= Double(allowedHours) * 3_600 + 15 * 60
                && (first.planTier == nil || last.planTier == nil || first.planTier == last.planTier)
                && (reset != nil || last.usedPercent >= first.usedPercent)
        }

        func unwrapped(at time: TimeInterval) -> Double {
            guard let reset else {
                return first.usedPercent + (last.usedPercent - first.usedPercent) * (time - start) / (end - start)
            }
            if time >= end { return first.usedPercent + oldCycleTail + last.usedPercent }
            if time <= reset {
                return first.usedPercent + oldCycleTail * (time - start) / (reset - start)
            }
            return first.usedPercent + oldCycleTail + last.usedPercent * (time - reset) / (end - reset)
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
