import Foundation

protocol ClaudeHTTPTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionClaudeHTTPTransport: ClaudeHTTPTransport {
    let session: URLSession

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeFailure.transient("Claude usage response was not HTTP")
        }
        return (data, http)
    }
}

struct ClaudeOAuthClient: ClaudeOAuthQuery {
    let credentials: ClaudeCredentialLoader
    let http: any ClaudeHTTPTransport
    let now: @Sendable () -> Date

    init(
        credentials: ClaudeCredentialLoader = ClaudeCredentialLoader(),
        http: any ClaudeHTTPTransport = URLSessionClaudeHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    func quota(account: AccountID) async throws -> ClaudeObservation? {
        guard account.provider == .claude else { throw ProbeFailure.permanent("Wrong provider") }
        let credential = try await Task.detached(priority: .utility) {
            try credentials.load(account: account)
        }.value
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ProbeFailure.permanent("Claude usage URL is invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await http.get(request)
        switch response.statusCode {
        case 200:
            return try ClaudePayload.oauth(data, observedAt: now())
        case 401, 403:
            throw ProbeFailure.permanent("Claude OAuth authentication failed")
        default:
            throw ProbeFailure.transient("Claude usage request failed")
        }
    }
}
