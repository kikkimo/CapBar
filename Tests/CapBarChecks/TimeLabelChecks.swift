import Foundation
@testable import CapBarCore

@MainActor func runTimeLabelChecks() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    check(capturedAtLabel(now.addingTimeInterval(-180), now: now, calendar: calendar) == "刚刚", "three-minute boundary is just now")
    check(capturedAtLabel(now.addingTimeInterval(-240), now: now, calendar: calendar) == "4 分钟前", "four minutes is relative")
    check(capturedAtLabel(now.addingTimeInterval(-3540), now: now, calendar: calendar) == "59 分钟前", "59 minutes is relative")
    let hour = capturedAtLabel(now.addingTimeInterval(-3600), now: now, calendar: calendar)
    check(!hour.contains("分钟前") && hour.contains(":"), "60 minutes uses a concrete local time")
    let priorYear = capturedAtLabel(now.addingTimeInterval(-400 * 86400), now: now, calendar: calendar)
    check(priorYear.contains("2025"), "cross-year time includes the year")
    check(capturedAtLabel(nil, now: now, calendar: calendar) == "尚未采集", "missing snapshot has no false age")
}
