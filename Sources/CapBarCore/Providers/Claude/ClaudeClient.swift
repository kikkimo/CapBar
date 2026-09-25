import Foundation

protocol ClaudeTerminalSession: Sendable {
    func start(account: AccountID) async throws
    func converse() async throws -> ClaudeObservation?
    func exit() async
    func terminate() async
}

protocol ClaudeOAuthQuery: Sendable {
    func quota(account: AccountID) async throws -> ClaudeObservation?
}

protocol ClaudeIdentityQuery: Sendable {
    func identity(account: AccountID) async throws -> AccountIdentity
}

struct ClaudeClient: UsageProvider {
    let terminalFactory: @Sendable () -> any ClaudeTerminalSession
    let oauth: any ClaudeOAuthQuery
    let identityQuery: any ClaudeIdentityQuery
    let now: @Sendable () -> Date

    init(
        terminalFactory: @escaping @Sendable () -> any ClaudeTerminalSession = { ClaudeTerminalProcess() },
        oauth: any ClaudeOAuthQuery = ClaudeOAuthClient(),
        identity: any ClaudeIdentityQuery = ClaudeIdentityCLI(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.terminalFactory = terminalFactory
        self.oauth = oauth
        self.identityQuery = identity
        self.now = now
    }

    func probe(account: AccountID) async throws -> UsageSnapshot {
        guard account.provider == .claude else { throw ProbeFailure.permanent("Wrong provider") }
        let identity = try await identityQuery.identity(account: account)
        let terminal = terminalFactory()
        var started = false
        var statusline: ClaudeObservation?
        do {
            try await terminal.start(account: account)
            started = true
            statusline = try await terminal.converse()
        } catch {
            // A session may fail to produce statusline while OAuth remains usable.
        }
        if Task.isCancelled {
            await terminal.terminate()
            throw CancellationError()
        }
        let oauthObservation = try? await oauth.quota(account: account)
        if started { await terminal.exit() }
        await terminal.terminate()
        try Task.checkCancellation()
        return try ClaudeObservation.select(statusline, oauthObservation, identity: identity, capturedAt: now())
    }
}
