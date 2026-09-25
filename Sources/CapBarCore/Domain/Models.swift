import Foundation

enum Provider: String, Codable, Sendable {
    case claude
    case codex
}

struct AccountID: Hashable, Codable, Sendable {
    let provider: Provider
    let directory: String

    init(provider: Provider, directory: String) {
        self.provider = provider
        let expanded = (directory as NSString).expandingTildeInPath
        self.directory = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private enum CodingKeys: String, CodingKey { case provider, directory }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decode(Provider.self, forKey: .provider),
            directory: try container.decode(String.self, forKey: .directory)
        )
    }
}

struct AccountIdentity: Codable, Sendable {
    let email: String?
    let plan: String?
    let organization: String?
}

enum WindowKind: String, Codable, Sendable {
    case fiveHour
    case sevenDay
}

enum ModelValidationError: Error {
    case invalidPercentage
    case invalidProbePolicy
}

struct QuotaWindow: Codable, Sendable {
    let kind: WindowKind
    let remainingPercent: Double
    let resetsAt: Date?

    init(kind: WindowKind, remainingPercent: Double, resetsAt: Date?) throws {
        guard remainingPercent.isFinite, (0...100).contains(remainingPercent) else {
            throw ModelValidationError.invalidPercentage
        }
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey { case kind, remainingPercent, resetsAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(WindowKind.self, forKey: .kind),
            remainingPercent: container.decode(Double.self, forKey: .remainingPercent),
            resetsAt: container.decodeIfPresent(Date.self, forKey: .resetsAt)
        )
    }
}

struct UsageSnapshot: Codable, Sendable {
    let identity: AccountIdentity
    let windows: [QuotaWindow]
    let capturedAt: Date
}

struct ProbePolicy: Codable, Sendable {
    let maxAttempts: Int
    let attemptTimeoutSeconds: Double
    let retryDelayMinSeconds: Double
    let retryDelayMaxSeconds: Double

    init(maxAttempts: Int, attemptTimeoutSeconds: Double, retryDelayMinSeconds: Double, retryDelayMaxSeconds: Double) {
        self.maxAttempts = maxAttempts
        self.attemptTimeoutSeconds = attemptTimeoutSeconds
        self.retryDelayMinSeconds = retryDelayMinSeconds
        self.retryDelayMaxSeconds = retryDelayMaxSeconds
    }

    func validate() throws {
        guard maxAttempts > 0,
              attemptTimeoutSeconds.isFinite, (30...60).contains(attemptTimeoutSeconds),
              retryDelayMinSeconds.isFinite, retryDelayMaxSeconds.isFinite,
              retryDelayMinSeconds >= 0,
              retryDelayMinSeconds <= retryDelayMaxSeconds else {
            throw ModelValidationError.invalidProbePolicy
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maxAttempts, attemptTimeoutSeconds, retryDelayMinSeconds, retryDelayMaxSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxAttempts = try container.decode(Int.self, forKey: .maxAttempts)
        attemptTimeoutSeconds = try container.decode(Double.self, forKey: .attemptTimeoutSeconds)
        retryDelayMinSeconds = try container.decode(Double.self, forKey: .retryDelayMinSeconds)
        retryDelayMaxSeconds = try container.decode(Double.self, forKey: .retryDelayMaxSeconds)
        try validate()
    }

    static func bundled() throws -> ProbePolicy {
        guard let url = CapBarResources.url(forResource: "ProbePolicy", withExtension: "json") else {
            throw ModelValidationError.invalidProbePolicy
        }
        return try JSONDecoder().decode(ProbePolicy.self, from: Data(contentsOf: url))
    }
}
