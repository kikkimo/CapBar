import Foundation

indirect enum APIValue: Codable, Sendable, Equatable {
    case object([String: APIValue]), array([APIValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: APIValue].self) { self = .object(v) }
        else { self = .array(try c.decode([APIValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> APIValue { object?[key] ?? .null }
    var object: [String: APIValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [APIValue]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var number: Double? { if case .number(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    static func text(_ v: String?) -> Self { v.map(Self.string) ?? .null }
    static func numeric(_ v: Double?) -> Self { v.map(Self.number) ?? .null }
    static func date(_ v: Date?) -> Self { v.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }
}

struct ExternalResponse: Sendable {
    let status: Int
    let value: APIValue
    static func failure(_ status: Int, _ code: String, _ message: String) -> Self {
        Self(status: status, value: .object([
            "api_version": .string("v1"), "request_id": .string(UUID().uuidString),
            "error": .object(["code": .string(code), "message": .string(message),
                              "retryable": .bool(status == 429 || status == 503),
                              "retry_after_seconds": status == 429 || status == 503 ? .number(5) : .null])
        ]))
    }
}

struct ExternalAccessSettings: Codable, Sendable, Equatable {
    var enabled = false
    var allowOneShotRefresh = false
    enum CodingKeys: String, CodingKey {
        case enabled
        case allowOneShotRefresh = "allow_one_shot_refresh"
    }
}

struct APIError: Error {
    let status: Int
    let code: String
    let message: String
    static let argument = Self(status: 400, code: "INVALID_ARGUMENT", message: "参数无效或包含不支持的字段")
}

extension APIValue {
    func fields(_ allowed: Set<String>, required: Set<String> = []) throws -> [String: APIValue] {
        guard let object, Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else { throw APIError.argument }
        return object
    }
}

struct APIRateLimit {
    var tokens: Double
    let capacity: Double
    let perSecond: Double
    var updatedAt = Date()
    mutating func take(now: Date = Date()) -> Bool {
        tokens = min(capacity, tokens + max(0, now.timeIntervalSince(updatedAt)) * perSecond)
        updatedAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

struct ExternalAccessPolicy: Codable, Sendable {
    let requestsPerMinute: Double
    let requestBurst: Double
    let refreshBatchesPerMinute: Double
    let refreshBurst: Double
    let maximumConcurrentProbes: Int
    let maximumQueuedAccounts: Int
    let maximumActiveJobs: Int
    let maximumRetainedJobs: Int
    let jobRetentionSeconds: Double

    static func bundled() throws -> Self {
        guard let url = CapBarResources.url(forResource: "ExternalAccessPolicy", withExtension: "json") else { throw APIError.argument }
        let policy = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard [policy.requestsPerMinute, policy.requestBurst, policy.refreshBatchesPerMinute, policy.refreshBurst, policy.jobRetentionSeconds].allSatisfy({ $0.isFinite && $0 > 0 }),
              [policy.maximumConcurrentProbes, policy.maximumQueuedAccounts, policy.maximumActiveJobs, policy.maximumRetainedJobs].allSatisfy({ $0 > 0 }) else { throw APIError.argument }
        return policy
    }
}
