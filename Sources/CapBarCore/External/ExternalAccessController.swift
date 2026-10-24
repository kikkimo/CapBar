import Foundation

@MainActor final class ExternalAccessController {
    private let settingsStore: SettingsStore
    private let coordinator: RefreshCoordinator
    private let history: UsageHistoryStore
    private var service: ExternalService?
    private var server: UnixHTTPServer?

    init(settingsStore: SettingsStore, coordinator: RefreshCoordinator, history: UsageHistoryStore) {
        self.settingsStore = settingsStore; self.coordinator = coordinator; self.history = history
    }
    func update(_ settings: ExternalAccessSettings) async throws {
        if !settings.enabled { stop(); return }
        if server != nil { return }
        let token = try ExternalCredentials.create()
        let api: ExternalService
        if let service { api = service }
        else {
            api = try ExternalService(settingsStore: settingsStore, coordinator: coordinator, historyStore: history,
                registryURL: ExternalCredentials.directory.appendingPathComponent("account-ids.json"), token: token)
            service = api
        }
        await api.setToken(token)
        // Cancellation of a DispatchSource closes the old socket asynchronously.
        for attempt in 0..<5 {
            do {
                server = try UnixHTTPServer(path: ExternalCredentials.socketPath) { request in
                    await api.handle(method: request.method, path: request.path, body: request.body, token: request.token)
                }
                return
            } catch {
                if attempt == 4 { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func resetKey() async throws {
        let token = try ExternalCredentials.create(rotate: true)
        await service?.setToken(token)
    }
    func stop() { server?.stop(); server = nil }

    static func mcpConfiguration(bundle: URL = Bundle.main.bundleURL) -> String {
        let app = bundle.pathExtension == "app" ? bundle : URL(fileURLWithPath: "/Applications/CapBar.app")
        let value: APIValue = .object(["mcpServers": .object(["capbar": .object([
            "command": .string(app.appendingPathComponent("Contents/MacOS/capbar-mcp").path)
        ])])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? value.encoded(), as: UTF8.self)
    }
    static var localAccessInformation: String {
        """
        CapBar 本地接口（只读查询；刷新需单独开启）：
        Socket: \(ExternalCredentials.socketPath)
        Header file: \(ExternalCredentials.directory.appendingPathComponent("authorization.header").path)
        GET /v1/status
        GET /v1/accounts
        POST /v1/quotas/query
        POST /v1/usage/query
        POST /v1/statistics/query
        POST /v1/records/query
        POST /v1/refresh-jobs （单次刷新）
        GET /v1/refresh-jobs/{job_id}
        Host: capbar.local
        凭据保存在私有 header 文件；此接入信息不包含密钥。
        """
    }
}
