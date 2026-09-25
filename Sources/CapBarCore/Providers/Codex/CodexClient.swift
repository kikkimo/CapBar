import Foundation

protocol CodexTransport: Sendable {
    func read(account: AccountID) async throws -> (Data, Data)
}

struct CodexClient: UsageProvider {
    let transport: any CodexTransport
    let now: @Sendable () -> Date

    init(transport: any CodexTransport = CodexProcess(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    func probe(account: AccountID) async throws -> UsageSnapshot {
        guard account.provider == .codex else { throw ProbeFailure.permanent("Wrong provider") }
        let (accountData, limitsData) = try await transport.read(account: account)
        let identity = try CodexPayload.decodeAccount(accountData)
        let windows = try CodexPayload.decodeRateLimits(limitsData)
        return UsageSnapshot(identity: identity, windows: windows, capturedAt: now())
    }
}
