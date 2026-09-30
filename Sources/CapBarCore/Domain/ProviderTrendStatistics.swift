import Foundation

struct TrendIntervalPeak: Sendable {
    let value: Double
    let endAt: Date
}

struct TrendAccountLeader: Sendable {
    let label: String
    let equivalentPercent: Double
    let sharePercent: Double
}

struct TrendUsageWindow: Sendable {
    let usedPercent: Double?
    let validBinCount: Int
    let expectedBinCount: Int

    var isComplete: Bool { validBinCount == expectedBinCount }
}

struct TrendHighUsagePeriod: Sendable {
    let startHour: Int
    let endHour: Int

    var label: String { String(format: "%02d:00–%02d:00", startHour, endHour) }
}

struct ProviderTrendStatistics: Sendable {
    let peak: TrendIntervalPeak?
    let minimum: Double?
    let average: Double?
    let observedTotal: Double?
    let validBinCount: Int
    let expectedBinCount: Int
    let leader: TrendAccountLeader?
    let highUsagePeriod: TrendHighUsagePeriod?
    let recent24Hours: TrendUsageWindow
    let changePercent: Double?
}

extension ProviderTrendOverview {
    func statistics(calendar: Calendar) -> ProviderTrendStatistics? {
        guard let series else { return nil }
        let valid = series.points.compactMap { point -> (endAt: Date, usage: Double)? in
            guard let usage = point.usedPercent, usage.isFinite, usage >= 0 else { return nil }
            return (point.endAt, usage)
        }
        let total = valid.isEmpty ? nil : valid.reduce(0) { $0 + $1.usage }
        var peak: TrendIntervalPeak?
        for point in valid where peak == nil || point.usage >= peak!.value {
            peak = TrendIntervalPeak(value: point.usage, endAt: point.endAt)
        }

        let binsPerDay = 24 / series.binHours
        let recent = usageWindow(in: series.points, offsetFromEnd: 0, count: binsPerDay)
        let previous = usageWindow(in: series.points, offsetFromEnd: binsPerDay, count: binsPerDay)
        let change: Double?
        if recent.isComplete, previous.isComplete,
           let current = recent.usedPercent, let earlier = previous.usedPercent {
            change = earlier > 0 ? (current / earlier - 1) * 100 : current == 0 ? 0 : nil
        } else {
            change = nil
        }

        return ProviderTrendStatistics(
            peak: peak,
            minimum: valid.map(\.usage).min(),
            average: total.map { $0 / Double(valid.count) },
            observedTotal: total,
            validBinCount: valid.count,
            expectedBinCount: series.points.count,
            leader: total.flatMap { leadingAccount(total: $0, validEnds: valid.map(\.endAt)) },
            highUsagePeriod: highUsagePeriod(valid: valid, binHours: series.binHours, calendar: calendar),
            recent24Hours: recent,
            changePercent: change
        )
    }

    private func leadingAccount(total: Double, validEnds: [Date]) -> TrendAccountLeader? {
        guard total > 0, !accounts.isEmpty else { return nil }
        var totals = [Double](repeating: 0, count: accounts.count)
        var labels: [String] = []
        for endAt in validEnds {
            guard let contributions = contributions(at: endAt), contributions.count == totals.count else { continue }
            if labels.isEmpty { labels = contributions.map(\.label) }
            for (index, contribution) in contributions.enumerated() {
                totals[index] += contribution.equivalentPercent
            }
        }
        guard let index = totals.indices.max(by: { totals[$0] < totals[$1] }), totals[index] > 0,
              labels.indices.contains(index) else { return nil }
        return TrendAccountLeader(label: labels[index], equivalentPercent: totals[index],
                                  sharePercent: totals[index] / total * 100)
    }

    private func usageWindow(in points: [UsageTrendPoint], offsetFromEnd: Int, count: Int) -> TrendUsageWindow {
        let end = max(0, points.count - offsetFromEnd)
        let start = max(0, end - count)
        let values = points[start..<end].compactMap(\.usedPercent).filter { $0.isFinite && $0 >= 0 }
        return TrendUsageWindow(usedPercent: values.isEmpty ? nil : values.reduce(0, +),
                                validBinCount: values.count, expectedBinCount: count)
    }

    private func highUsagePeriod(valid: [(endAt: Date, usage: Double)], binHours: Int,
                                 calendar: Calendar) -> TrendHighUsagePeriod? {
        let duration = TimeInterval(binHours * 3_600)
        guard Double(valid.count) * duration >= 24 * 3_600,
              Set(valid.map { calendar.startOfDay(for: $0.endAt.addingTimeInterval(-duration / 2)) }).count >= 2
        else { return nil }

        let periodHours = max(6, binHours)
        let periodCount = 24 / periodHours
        var usage = [Double](repeating: 0, count: periodCount)
        var observedSeconds = [TimeInterval](repeating: 0, count: periodCount)
        var observedDays = [Set<Date>](repeating: [], count: periodCount)
        for point in valid {
            var cursor = point.endAt.addingTimeInterval(-duration)
            while cursor < point.endAt.addingTimeInterval(-0.000_001) {
                let withinHour = cursor.addingTimeInterval(0.000_001)
                guard let hour = calendar.dateInterval(of: .hour, for: withinHour) else { break }
                let stop = min(hour.end, point.endAt)
                guard stop > cursor else { break }
                let bucket = calendar.component(.hour, from: withinHour) / periodHours
                let seconds = stop.timeIntervalSince(cursor)
                usage[bucket] += point.usage * seconds / duration
                observedSeconds[bucket] += seconds
                observedDays[bucket].insert(calendar.startOfDay(for: withinHour))
                cursor = stop
            }
        }

        var best: (index: Int, rate: Double)?
        for index in 0..<periodCount where observedDays[index].count >= 2 && observedSeconds[index] > 0 {
            let rate = usage[index] / observedSeconds[index]
            if best == nil || rate > best!.rate { best = (index, rate) }
        }
        guard let best else { return nil }
        return TrendHighUsagePeriod(startHour: best.index * periodHours,
                                    endHour: (best.index + 1) * periodHours)
    }
}
