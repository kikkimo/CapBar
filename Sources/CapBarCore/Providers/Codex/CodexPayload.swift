import Foundation

private struct RPCReply<Value: Decodable>: Decodable {
    let result: Value?
    let error: RPCFault?
}

private struct RPCFault: Decodable {
    let code: Int?
    let message: String?
}

private struct AccountResult: Decodable {
    let account: AccountInfo?
}

private struct AccountInfo: Decodable {
    let type: String
    let email: String?
    let planType: String?
}

private struct LimitsResult: Decodable {
    let rateLimits: LimitBucket?
    let rateLimitsByLimitId: [String: LimitBucket]?
}

private struct LimitBucket: Decodable {
    let primary: LimitWindow?
    let secondary: LimitWindow?
}

private struct LimitWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}

enum CodexPayload {
    static func decodeAccount(_ data: Data) throws -> AccountIdentity {
        let reply = try JSONDecoder().decode(RPCReply<AccountResult>.self, from: data)
        if reply.error != nil { throw ProbeFailure.permanent("Codex account request rejected") }
        guard let account = reply.result?.account else {
            throw ProbeFailure.permanent("Codex account is not signed in")
        }
        return AccountIdentity(email: account.email, plan: account.planType, organization: nil)
    }

    static func decodeRateLimits(_ data: Data) throws -> [QuotaWindow] {
        let reply = try JSONDecoder().decode(RPCReply<LimitsResult>.self, from: data)
        if reply.error != nil { throw ProbeFailure.transient("Codex rate limit request failed") }
        guard let result = reply.result,
              let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits else {
            throw ProbeFailure.transient("Codex rate limits unavailable")
        }

        var windows: [WindowKind: QuotaWindow] = [:]
        for candidate in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
            guard let duration = candidate.windowDurationMins,
                  let used = candidate.usedPercent, used.isFinite, (0...100).contains(used) else { continue }
            let kind: WindowKind
            switch duration {
            case 300: kind = .fiveHour
            case 10080: kind = .sevenDay
            default: continue
            }
            let reset = candidate.resetsAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            windows[kind] = try QuotaWindow(kind: kind, remainingPercent: 100 - used, resetsAt: reset)
        }
        guard !windows.isEmpty else { throw ProbeFailure.transient("Codex quota windows unavailable") }
        return [.fiveHour, .sevenDay].compactMap { windows[$0] }
    }
}
