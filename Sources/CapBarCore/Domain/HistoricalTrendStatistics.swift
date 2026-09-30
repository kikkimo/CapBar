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

    static func calculate(series: UsageTrendSeries, calendar: Calendar) -> Self {
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

        let completeDays = days.compactMap { start, day -> HistoricalUsageRecord? in
            guard let interval = calendar.dateInterval(of: .day, for: start),
                  abs(day.covered - interval.duration) < 1 else { return nil }
            return HistoricalUsageRecord(usedPercent: day.usage, startsAt: start, endsAt: interval.end)
        }
        let byStart = Dictionary(uniqueKeysWithValues: completeDays.map { ($0.startsAt, $0) })
        let highDay = completeDays.max { $0.usedPercent < $1.usedPercent }

        var highWeek: HistoricalUsageRecord?
        var lowWeek: HistoricalUsageRecord?
        for start in completeDays.map(\.startsAt).sorted() {
            var total = 0.0
            var complete = true
            for offset in 0..<7 {
                guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start),
                      let day = byStart[dayStart] else { complete = false; break }
                total += day.usedPercent
            }
            guard complete, let end = calendar.date(byAdding: .day, value: 7, to: start) else { continue }
            let record = HistoricalUsageRecord(usedPercent: total, startsAt: start, endsAt: end)
            if highWeek == nil || total > highWeek!.usedPercent { highWeek = record }
            if lowWeek == nil || total < lowWeek!.usedPercent { lowWeek = record }
        }
        return Self(highSevenDays: highWeek, lowSevenDays: lowWeek,
                    highDay: highDay, highInterval: highInterval)
    }
}
