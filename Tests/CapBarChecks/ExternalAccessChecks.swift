import Foundation
@testable import CapBarCore

private actor ExternalProbe: UsageProvider {
    var calls = 0
    var release = false
    func probe(account: AccountID) async throws -> UsageSnapshot {
        calls += 1
        while !release { try await Task.sleep(for: .milliseconds(10)) }
        return UsageSnapshot(identity: AccountIdentity(email: "test@example.com", plan: "pro", organization: nil),
            windows: [try QuotaWindow(kind: .sevenDay, remainingPercent: 75, resetsAt: Date().addingTimeInterval(86400))], capturedAt: Date())
    }
    func finish() { release = true }
}

@MainActor func runExternalAccessChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let settingsStore = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let snapshots = SnapshotStore(url: folder.appendingPathComponent("snapshots.json"))
        let history = UsageHistoryStore(url: folder.appendingPathComponent("history.sqlite3"))
        let account = AccountID(provider: .claude, directory: folder.appendingPathComponent("account").path)
        var settings = UserSettings(accounts: [account], defaultsSeeded: true, autoRefreshOnOpen: false, refreshThresholdMinutes: 5)
        try await settingsStore.save(settings)
        let probe = ExternalProbe()
        let coordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshots,
            historyStore: history, providers: [.claude: probe], policy: ProbePolicy.bundled())
        let api = try ExternalService(settingsStore: settingsStore, coordinator: coordinator, historyStore: history,
            registryURL: folder.appendingPathComponent("ids.json"), token: "test-token")
        func request(_ path: String, _ body: APIValue = .object([:]), method: String = "POST", token: String = "test-token") async -> ExternalResponse {
            await api.handle(method: method, path: path, body: body, token: token)
        }
        check(await request("/v1/status", method: "GET").status == 503, "external access defaults off")
        settings.externalAccess.enabled = true
        try await settingsStore.save(settings)
        check(await request("/v1/status", method: "GET", token: "wrong").status == 401, "external queries require authentication")
        let status = await request("/v1/status", method: "GET")
        check(status.status == 200, "enabled read access provides status")
        let accounts = await request("/v1/accounts", method: "GET")
        let id = accounts.value["data"]["accounts"].array?.first?["account_id"].string ?? "missing"
        check(id.hasPrefix("acc_"), "external account ID is opaque")
        check(!String(decoding: accounts.value.encoded(), as: UTF8.self).contains(folder.path), "account listing hides filesystem paths")
        let selector: APIValue = .object(["selector": .object(["all": .bool(true)])])
        check(await request("/v1/quotas/query", selector).status == 200, "quota query reads empty snapshot without probing")
        for path in ["/v1/usage/query", "/v1/statistics/query", "/v1/records/query"] {
            let body: APIValue = path.contains("usage/") ? .object(["target": .object(["account_id": .string(id)])]) : .object(["provider": .string("claude")])
            _ = await request(path, body)
        }
        check(await probe.calls == 0, "all reads including analytics start zero provider sessions")
        let key = UUID().uuidString
        let refresh: APIValue = .object(["selector": selector["selector"], "instance_id": status.value["data"]["instance_id"], "request_key": .string(key)])
        check(await request("/v1/refresh-jobs", refresh).status == 403, "readonly mode rejects refresh")
        settings.externalAccess.allowOneShotRefresh = true
        try await settingsStore.save(settings)
        var bad = refresh.object!; bad["interval"] = .number(60)
        check(await request("/v1/refresh-jobs", .object(bad)).status == 400, "scheduled refresh parameters are forbidden")
        check(await request("/v1/settings", .object(["enabled": .bool(true)])).status == 404, "no external settings mutation endpoint")
        let one = await request("/v1/refresh-jobs", refresh)
        let two = await request("/v1/refresh-jobs", refresh)
        check(one.status == 202 && one.value["data"]["job_id"] == two.value["data"]["job_id"], "retry uses same job and no new probe")
        for _ in 0..<100 { if await probe.calls > 0 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        check(await probe.calls == 1, "single external refresh starts one provider call")
        check(!(await coordinator.requestRefresh(account)), "UI refresh cannot duplicate external refresh")
        var another = refresh.object!; another["request_key"] = .string(UUID().uuidString)
        let joined = await request("/v1/refresh-jobs", .object(another))
        check(joined.value["data"]["items"].array?.first?["action"].string == "joined", "another client joins the existing execution")
        await probe.finish()
        let jobID = one.value["data"]["job_id"].string ?? "missing"
        var completed = one
        for _ in 0..<100 {
            completed = await request("/v1/refresh-jobs/" + jobID, method: "GET")
            if completed.value["data"]["state"].string == "completed" { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        check(completed.value["data"]["state"].string == "completed", "single refresh reaches terminal state")
        check(await probe.calls == 1, "polling never schedules another refresh")
        let samples = try await history.samples(account: account, from: .distantPast, through: Date())
        check(samples.isEmpty, "external refresh never enables statistics or writes disabled history")
        let saved = try await settingsStore.loadOrSeed()
        check(!saved.usageStatisticsEnabled && !saved.autoRefreshOnOpen, "external refresh preserves sampling and auto-open settings")
        let quotas = await request("/v1/quotas/query", selector)
        check(quotas.value["data"]["accounts"].array?.first?["windows"].array?.first?["remaining_percent"].number == 75, "external refresh updates shared snapshot")
        await coordinator.cancelAll()
    } catch { check(false, "external test setup: \(error)") }
}
