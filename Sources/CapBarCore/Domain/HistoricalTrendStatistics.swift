import Foundation

struct HistoricalUsageRecord: Codable, Equatable, Sendable {
    let usedPercent: Double
    let startsAt: Date
    let endsAt: Date
}

struct HistoricalTrendStatistics: Codable, Equatable, Sendable {
    let highSevenDays: HistoricalUsageRecord?
    let lowSevenDays: HistoricalUsageRecord?
    let highDay: HistoricalUsageRecord?
    let highInterval: HistoricalUsageRecord?

    static func calculate(series: UsageTrendSeries, calendar: Calendar,
                          firstSampleAt: Date? = nil, endingAt: Date? = nil) -> Self {
        let duration = TimeInterval(series.binHours * 3_600)
        var days: [Date: (usage: Double, covered: TimeInterval)] = [:]
        var highInterval: HistoricalUsageRecord?

        for point in series.points {
            guard let amount = point.usedPercent, amount.isFinite, amount >= 0 else { continue }
            let start = point.endAt.addingTimeInterval(-duration)
            let record = HistoricalUsageRecord(usedPercent: amount, startsAt: start, endsAt: point.endAt)
            if highInterval == nil || amount >= highInterval!.usedPercent { highInterval = record }

            var cursor = start
            while cursor < point.endAt.addingTimeInterval(-0.000_001) {
                guard let day = calendar.dateInterval(of: .day, for: cursor.addingTimeInterval(0.000_001))
                else { break }
                let stop = min(day.end, point.endAt)
                guard stop > cursor else { break }
                let seconds = stop.timeIntervalSince(cursor)
                var accumulated = days[day.start] ?? (usage: 0, covered: 0)
                accumulated.usage += amount * seconds / duration
                accumulated.covered += seconds
                days[day.start] = accumulated
                cursor = stop
            }
        }

        // Missing intervals contribute zero. Only elapsed local calendar days qualify;
        // never invent history before the first sample's local date.
        let firstObserved = series.points.first { $0.usedPercent != nil }
        let firstDate = firstSampleAt ?? firstObserved?.endAt.addingTimeInterval(-duration)
        let endDate = endingAt ?? series.points.map(\.endAt).max()
        guard let firstDate, let endDate else {
            return Self(highSevenDays: nil, lowSevenDays: nil, highDay: nil, highInterval: highInterval)
        }
        let completedBefore = calendar.startOfDay(for: endDate)
        var cursor = calendar.startOfDay(for: firstDate)
        var records: [HistoricalUsageRecord] = []
        var highDay: HistoricalUsageRecord?
        var highWeek: HistoricalUsageRecord?
        var lowWeek: HistoricalUsageRecord?
        var rollingTotal = 0.0
        while cursor < completedBefore {
            guard let end = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let record = HistoricalUsageRecord(usedPercent: days[cursor]?.usage ?? 0,
                                               startsAt: cursor, endsAt: end)
            records.append(record)
            if highDay == nil || record.usedPercent > highDay!.usedPercent { highDay = record }
            rollingTotal += record.usedPercent
            if records.count > 7 { rollingTotal -= records[records.count - 8].usedPercent }
            if records.count >= 7 {
                let week = HistoricalUsageRecord(usedPercent: max(0, rollingTotal),
                    startsAt: records[records.count - 7].startsAt, endsAt: end)
                if highWeek == nil || week.usedPercent > highWeek!.usedPercent { highWeek = week }
                if lowWeek == nil || week.usedPercent < lowWeek!.usedPercent { lowWeek = week }
            }
            cursor = end
        }
        return Self(highSevenDays: highWeek, lowSevenDays: lowWeek,
                    highDay: highDay, highInterval: highInterval)
    }
}
