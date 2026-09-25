import Foundation

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
