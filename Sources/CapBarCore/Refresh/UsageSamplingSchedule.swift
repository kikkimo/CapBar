import Foundation

enum UsageSamplingSchedule {
    private static let hour: TimeInterval = 3_600
    private static let postResetDelay: TimeInterval = 5 * 60
    private static let epsilon: TimeInterval = 0.000_001

    static func nextRegular(after time: Date, intervalHours: Int) -> Date {
        let period = Double(intervalHours) * hour
        let next = (floor(time.timeIntervalSince1970 / period) + 1) * period
        return Date(timeIntervalSince1970: next)
    }

    static func nextEvent(after time: Date, intervalHours: Int, resetAt: Date?) -> Date {
        var regular = nextRegular(after: time, intervalHours: intervalHours)
        guard let resetAt else { return regular }
        if abs(regular.timeIntervalSince(resetAt)) < epsilon {
            regular = nextRegular(after: regular, intervalHours: intervalHours)
        }
        guard let special = nextSpecial(after: time, intervalHours: intervalHours, resetAt: resetAt) else {
            return regular
        }
        return min(regular, special)
    }

    static func previousEvent(atOrBefore time: Date, intervalHours: Int, resetAt: Date?) -> Date {
        let period = Double(intervalHours) * hour
        var regular = Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / period) * period)
        guard let resetAt else { return regular }
        if abs(regular.timeIntervalSince(resetAt)) < epsilon {
            regular = regular.addingTimeInterval(-period)
        }
        let start = resetAt.addingTimeInterval(-period)
        let post = resetAt.addingTimeInterval(postResetDelay)
        if time >= post { return max(regular, post) }
        guard time >= start else { return regular }
        let latestPreReset = min(time.timeIntervalSince1970, resetAt.timeIntervalSince1970 - epsilon)
        let steps = floor((latestPreReset - start.timeIntervalSince1970) / hour)
        let special = start.addingTimeInterval(max(0, steps) * hour)
        return max(regular, special)
    }

    private static func nextSpecial(after time: Date, intervalHours: Int, resetAt: Date) -> Date? {
        let start = resetAt.addingTimeInterval(-Double(intervalHours) * hour)
        if time < start { return start }
        if time < resetAt {
            let steps = floor(time.timeIntervalSince(start) / hour) + 1
            let hourly = start.addingTimeInterval(steps * hour)
            if hourly < resetAt - epsilon { return hourly }
        }
        let post = resetAt.addingTimeInterval(postResetDelay)
        return time < post ? post : nil
    }
}
