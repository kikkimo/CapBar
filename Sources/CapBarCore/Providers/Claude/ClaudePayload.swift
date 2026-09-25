import Foundation

private struct StatuslinePayload: Decodable {
    let rateLimits: StatuslineLimits?

    enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
}

private struct StatuslineLimits: Decodable {
    let fiveHour: StatuslineWindow?
    let sevenDay: StatuslineWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct StatuslineWindow: Decodable {
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

private struct OAuthPayload: Decodable {
    let fiveHour: OAuthWindow?
    let sevenDay: OAuthWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct OAuthWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct AuthStatusPayload: Decodable {
    let loggedIn: Bool
    let email: String?
    let orgName: String?
    let subscriptionType: String?
}

enum ClaudePayload {
    static func statusline(_ data: Data, observedAt: Date) throws -> ClaudeObservation {
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: data)
        var windows: [WindowKind: QuotaWindow] = [:]
        if let five = payload.rateLimits?.fiveHour,
           let window = makeWindow(.fiveHour, used: five.usedPercentage, reset: five.resetsAt.flatMap(epochDate)) {
            windows[.fiveHour] = window
        }
        if let week = payload.rateLimits?.sevenDay,
           let window = makeWindow(.sevenDay, used: week.usedPercentage, reset: week.resetsAt.flatMap(epochDate)) {
            windows[.sevenDay] = window
        }
        return ClaudeObservation(windows: windows, observedAt: observedAt)
    }

    static func oauth(_ data: Data, observedAt: Date) throws -> ClaudeObservation {
        let payload = try JSONDecoder().decode(OAuthPayload.self, from: data)
        var windows: [WindowKind: QuotaWindow] = [:]
        if let five = payload.fiveHour,
           let window = makeWindow(.fiveHour, used: five.utilization, reset: parseISO8601(five.resetsAt)) {
            windows[.fiveHour] = window
        }
        if let week = payload.sevenDay,
           let window = makeWindow(.sevenDay, used: week.utilization, reset: parseISO8601(week.resetsAt)) {
            windows[.sevenDay] = window
        }
        return ClaudeObservation(windows: windows, observedAt: observedAt)
    }

    static func authStatus(_ data: Data) throws -> AccountIdentity {
        let payload = try JSONDecoder().decode(AuthStatusPayload.self, from: data)
        guard payload.loggedIn else { throw ProbeFailure.permanent("Claude is not signed in") }
        return AccountIdentity(email: payload.email, plan: payload.subscriptionType, organization: payload.orgName)
    }

    private static func makeWindow(_ kind: WindowKind, used: Double?, reset: Date?) -> QuotaWindow? {
        guard let used, used.isFinite, (0...100).contains(used) else { return nil }
        return try? QuotaWindow(kind: kind, remainingPercent: 100 - used, resetsAt: reset)
    }

    private static func epochDate(_ seconds: Double) -> Date? {
        seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }

    private static func parseISO8601(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
