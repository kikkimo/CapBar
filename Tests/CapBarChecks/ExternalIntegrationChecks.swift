import Foundation
import Darwin
@testable import CapBarCore

private actor ExternalGateProvider: UsageProvider {
    var counts: [AccountID: Int] = [:]
    var released: Set<AccountID> = []
    func probe(account: AccountID) async throws -> UsageSnapshot {
        counts[account, default: 0] += 1
        while !released.contains(account) { try await Task.sleep(for: .milliseconds(10)) }
        return UsageSnapshot(identity: AccountIdentity(email: "fixture@example.com", plan: "pro", organization: "Fixture"),
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 50, resetsAt: Date().addingTimeInterval(86400))], capturedAt: Date())
    }
    func count(_ a: AccountID) -> Int { counts[a, default: 0] }
    func release(_ accounts: [AccountID]) { released.formUnion(accounts) }
}

@MainActor func runExternalIntegrationChecks() async {
    let root = URL(fileURLWithPath: "/tmp/capbar-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try ExternalCredentials.prepareDirectory(root)
        let credentials = root.appendingPathComponent("credentials")
        let token = try ExternalCredentials.create(directory: credentials)
        let loadedToken = try ExternalCredentials.load(directory: credentials)
        check(token.count == 64 && loadedToken == token, "private random credentials persist")
        let link = root.appendingPathComponent("linked-credentials")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: credentials)
        checkThrows("credential reads reject symbolic-link directories") { _ = try ExternalCredentials.load(directory: link) }
        let rotated = try ExternalCredentials.create(directory: credentials, rotate: true)
        check(rotated != token, "key rotation generates a new secret")
        let settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let snapshotStore = SnapshotStore(url: root.appendingPathComponent("snapshots.json"))
        let history = UsageHistoryStore(url: root.appendingPathComponent("history.sqlite3"))
        let accounts = (0..<3).map { AccountID(provider: .claude, directory: root.appendingPathComponent("account-\($0)").path) }
        var settings = UserSettings(accounts: accounts, defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5,
            planOverrides: accounts.map { UsagePlanOverride(account: $0, tier: .claudePro) })
        let encoded = try JSONEncoder().encode(settings)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "external_access")
        let decoded = try JSONDecoder().decode(UserSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(!decoded.externalAccess.enabled && !decoded.externalAccess.allowOneShotRefresh, "legacy settings migrate with both switches off")
        settings.externalAccess.enabled = true
        settings.externalAccess.allowOneShotRefresh = true
        try await settingsStore.save(settings)
        let end = floor(Date().timeIntervalSince1970 / 14400) * 14400
        for i in 0...42 {
            let sample = UsageSnapshot(identity: AccountIdentity(email: "fixture@example.com", plan: "pro", organization: nil),
                windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 100 - Double(i), resetsAt: Date(timeIntervalSince1970: end + 86400))],
                capturedAt: Date(timeIntervalSince1970: end - Double(42 - i) * 14400))
            _ = try await history.append(account: accounts[0], snapshot: sample, planTier: .claudePro)
            if i == 42 { try await snapshotStore.update(AccountRecord(id: accounts[0], snapshot: sample, lastAttemptAt: sample.capturedAt, lastError: nil)) }
        }
        let probe = ExternalGateProvider()
        let coordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, historyStore: history,
            providers: [.claude: probe], policy: ProbePolicy.bundled())
        let registryURL = root.appendingPathComponent("ids.json")
        let api = try ExternalService(settingsStore: settingsStore, coordinator: coordinator, historyStore: history, registryURL: registryURL, token: rotated)
        let socket = root.appendingPathComponent("api.sock").path
        let server = try UnixHTTPServer(path: socket) { r in await api.handle(method: r.method, path: r.path, body: r.body, token: r.token) }
        defer { server.stop() }
        func request(_ route: String, _ body: APIValue = .object([:]), method: String = "POST", key: String? = nil) async throws -> ExternalResponse {
            let secret = key ?? rotated
            return try await Task.detached { try UnixHTTPClient.call(path: socket, token: secret, method: method, route: route, body: body) }.value
        }
        let denied = try await request("/v1/status", method: "GET", key: "wrong")
        check(denied.status == 401, "real socket rejects wrong bearer token (got \(denied.status))")
        let status = try await request("/v1/status", method: "GET")
        let instance = status.value["data"]["instance_id"]
        check(status.status == 200, "real socket roundtrip reaches service")
        checkThrows("second server cannot steal the existing socket") {
            _ = try UnixHTTPServer(path: socket) { _ in .failure(500, "TEST", "test") }
        }
        let listing = try await request("/v1/accounts", method: "GET")
        let ids = listing.value["data"]["accounts"].array!.map { $0["account_id"] }
        let second = try ExternalService(settingsStore: settingsStore, coordinator: coordinator, historyStore: history, registryURL: registryURL, token: rotated)
        let reloaded = await second.handle(method: "GET", path: "/v1/accounts", token: rotated)
        check(reloaded.value["data"]["accounts"].array!.map { $0["account_id"] } == ids, "account IDs survive service restart")
        let stats = try await request("/v1/statistics/query", .object(["provider": .string("claude")]))
        check(abs((stats.value["data"]["observed_total_percent"].number ?? -100) - 42) < 0.001, "provider statistics sum observed usage despite two missing accounts")
        let usage = try await request("/v1/usage/query", .object(["target": .object(["account_id": ids[0]])]))
        check(usage.value["data"]["points"].array?.count == 42, "API uses configured four-hour plotting bins")
        check(await probe.count(accounts[0]) == 0, "socket analytics never invokes provider")
        var bad: [String: APIValue] = ["selector": .object(["all": .bool(true)]), "request_key": .string(UUID().uuidString), "instance_id": .string("old")]
        check(try await request("/v1/refresh-jobs", .object(bad)).status == 409, "old process ID cannot replay a refresh")
        bad["instance_id"] = instance
        let job = try await request("/v1/refresh-jobs", .object(bad))
        for _ in 0..<100 { if await probe.count(accounts[1]) == 1 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        check(await probe.count(accounts[2]) == 0, "third external account queues behind two active probes")
        // A UI refresh completes while its external request is still queued.
        check(await coordinator.requestRefresh(accounts[2]), "UI may refresh an externally queued account")
        await probe.release([accounts[2]])
        for _ in 0..<100 { if await !coordinator.isRefreshing(accounts[2]) { break }; try? await Task.sleep(for: .milliseconds(10)) }
        await probe.release(accounts)
        try await Task.sleep(for: .milliseconds(400))
        let jobID = job.value["data"]["job_id"].string!
        let finished = try await request("/v1/refresh-jobs/" + jobID, method: "GET")
        check(finished.value["data"]["state"].string == "completed", "queued batch completes as one-shot")
        check(await probe.count(accounts[2]) == 1, "queued account reuses UI execution that already completed")
        var conflict = bad; conflict["selector"] = .object(["account_ids": .array([ids[0]])])
        check(try await request("/v1/refresh-jobs", .object(conflict)).status == 409, "same idempotency key cannot change selected accounts")
        await api.setToken("new-test-secret")
        check(try await request("/v1/status", method: "GET").status == 401, "rotated key rejected by running service")
        await coordinator.cancelAll()

        // Separate fixture: disable permission with queued work; only the two
        // already-started provider calls may finish.
        let gate = ExternalGateProvider()
        let blockedCoordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore,
            historyStore: history, providers: [.claude: gate], policy: ProbePolicy.bundled())
        let blockedAPI = try ExternalService(settingsStore: settingsStore, coordinator: blockedCoordinator, historyStore: history, registryURL: registryURL, token: token)
        let blockedStatus = await blockedAPI.handle(method: "GET", path: "/v1/status", token: token)
        let blockedJob = await blockedAPI.handle(method: "POST", path: "/v1/refresh-jobs", body: .object([
            "selector": .object(["all": .bool(true)]), "instance_id": blockedStatus.value["data"]["instance_id"], "request_key": .string(UUID().uuidString)
        ]), token: token)
        for _ in 0..<100 { if await gate.count(accounts[1]) == 1 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        settings.externalAccess.allowOneShotRefresh = false
        try await settingsStore.save(settings)
        await gate.release(accounts)
        try await Task.sleep(for: .milliseconds(400))
        let blockedResult = await blockedAPI.handle(method: "GET", path: "/v1/refresh-jobs/" + blockedJob.value["data"]["job_id"].string!, token: token)
        check(await gate.count(accounts[2]) == 0, "disabling permission prevents queued external probe from starting")
        check(blockedResult.value["data"]["items"].array?.last?["state"].string == "skipped", "queued revoked task reports skipped")
        await blockedCoordinator.cancelAll()
    } catch { check(false, "external integration: \(error)") }
}
