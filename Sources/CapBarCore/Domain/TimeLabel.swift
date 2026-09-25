import Foundation

enum CaptureAgeBand: Equatable, Sendable {
    case unknown, fresh, underTen, underThirty, underSixty, old
}

func captureAgeBand(_ date: Date?, now: Date) -> CaptureAgeBand {
    guard let date else { return .unknown }
    let age = max(0, now.timeIntervalSince(date))
    if age <= 180 { return .fresh }
    let minutes = Int(age / 60)
    if minutes <= 10 { return .underTen }
    if minutes <= 30 { return .underThirty }
    if minutes < 60 { return .underSixty }
    return .old
}

func capturedAtLabel(_ date: Date?, now: Date, calendar: Calendar) -> String {
    guard let date else { return "尚未采集" }
    let age = max(0, now.timeIntervalSince(date))
    if age <= 180 { return "刚刚" }
    if age < 3600 { return "\(Int(age / 60)) 分钟前" }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    let sameYear = calendar.component(.year, from: now) == calendar.component(.year, from: date)
    formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
}
