import Foundation

actor ExternalService {
    let settingsStore: SettingsStore
    let coordinator: RefreshCoordinator
    let historyStore: UsageHistoryStore
    let registryURL: URL
    var registry: ExternalIdentityRegistry
    var token: String
    let instanceID = UUID().uuidString
    let policy: ExternalAccessPolicy
    var requestRate: APIRateLimit
    var refreshRate: APIRateLimit
    var jobs: [String: Job] = [:]
    var keys: [String: String] = [:]
    var works: [UUID: Work] = [:]
    var queue: [UUID] = []
    var running = 0
    let analytics: ExternalAnalytics

    struct Job {
        let id: String
        let key: String
        let fingerprint: APIValue
        let createdAt = Date()
        var workIDs: [UUID] = []
        var enrolling = true
        var joinedWorkIDs: Set<UUID> = []
    }
    struct Work {
        let account: AccountID
        var action = "queued"
        var state = "queued"
        var execution: UUID?
        var result: RefreshExecution?
        var finishedAt: Date?
        var error: String?
        let enqueuedAt = Date()
    }

    init(settingsStore: SettingsStore, coordinator: RefreshCoordinator, historyStore: UsageHistoryStore,
         registryURL: URL, token: String) throws {
        self.settingsStore = settingsStore
        self.coordinator = coordinator
        self.historyStore = historyStore
        self.registryURL = registryURL
        self.token = token
        let policy = try ExternalAccessPolicy.bundled()
        self.policy = policy
        self.requestRate = APIRateLimit(tokens: policy.requestBurst, capacity: policy.requestBurst, perSecond: policy.requestsPerMinute / 60)
        self.refreshRate = APIRateLimit(tokens: policy.refreshBurst, capacity: policy.refreshBurst, perSecond: policy.refreshBatchesPerMinute / 60)
        self.analytics = ExternalAnalytics(history: historyStore)
        if FileManager.default.fileExists(atPath: registryURL.path) {
            registry = try JSONDecoder().decode(ExternalIdentityRegistry.self, from: Data(contentsOf: registryURL))
        } else { registry = ExternalIdentityRegistry() }
    }

    func setToken(_ value: String) { token = value }

    func handle(method: String, path: String, body: APIValue = .object([:]), token supplied: String) async -> ExternalResponse {
        do {
            let settings = try await settingsStore.loadOrSeed()
            guard settings.externalAccess.enabled else { return .failure(503, "SERVICE_UNAVAILABLE", "外部访问未开启") }
            guard ExternalCredentials.matches(supplied, token) else { return .failure(401, "UNAUTHENTICATED", "访问密钥无效") }
            guard requestRate.take() else { return .failure(429, "RATE_LIMITED", "请求过于频繁，请稍后重试") }
            try registry.synchronize(settings.accounts, url: registryURL)
            pruneJobs()
            let data: APIValue
            var status = 200
            switch (method, path) {
            case ("GET", "/v1/status"):
                _ = try body.fields([])
                data = .object([
                    "app_version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"),
                    "instance_id": .string(instanceID), "account_count": .number(Double(settings.accounts.count)),
                    "one_shot_refresh_allowed": .bool(settings.externalAccess.allowOneShotRefresh),
                    "statistics_enabled": .bool(settings.usageStatisticsEnabled),
                    "sampling_interval_hours": .number(Double(settings.samplingIntervalHours)),
                    "plot_interval_hours": .number(Double(max(2, settings.samplingIntervalHours))),
                    "time_zone": .string(TimeZone.current.identifier)
                ])
            case ("GET", "/v1/accounts"):
                _ = try body.fields(["provider"])
                let accounts = try providerAccounts(body, settings: settings, optional: true)
                let records = await coordinator.state()
                var values: [APIValue] = []
                for account in accounts {
                    let snapshot = records[account]?.snapshot
                    let tier = Self.tier(account, settings: settings, records: records)
                    values.append(.object([
                        "account_id": .string(registry.id(account)), "provider": .string(account.provider.rawValue),
                        "email": .text(snapshot?.identity.email), "organization": .text(snapshot?.identity.organization),
                        "plan": .object(["tier": .text(tier?.apiName), "display_name": .text(tier?.displayName ?? snapshot?.identity.plan),
                                         "source": .string(settings.planOverrides.contains { $0.account == account } ? "manual" : tier == nil ? "unknown" : "detected")]),
                        "has_snapshot": .bool(snapshot != nil), "refresh_state": .string(await refreshState(account))
                    ]))
                }
                data = .object(["accounts": .array(values)])
            case ("POST", "/v1/quotas/query"):
                _ = try body.fields(["selector"], required: ["selector"])
                let accounts = try select(body["selector"], settings: settings)
                let records = await coordinator.state()
                var values: [APIValue] = []
                for account in accounts { values.append(await quota(account, record: records[account])) }
                data = .object(["accounts": .array(values)])
            case ("POST", "/v1/refresh-jobs"):
                guard settings.externalAccess.allowOneShotRefresh else { return .failure(403, "REFRESH_DISABLED", "未开启外部单次刷新") }
                _ = try body.fields(["selector", "instance_id", "request_key"], required: ["selector", "instance_id", "request_key"])
                guard body["instance_id"].string == instanceID else { return .failure(409, "INSTANCE_CHANGED", "CapBar 已重启，请先读取当前状态") }
                guard let key = body["request_key"].string, UUID(uuidString: key) != nil else { throw APIError.argument }
                if let old = keys[key], let job = jobs[old] {
                    guard job.fingerprint == body else { return .failure(409, "IDEMPOTENCY_CONFLICT", "同一请求键不能用于不同的刷新") }
                    data = jobValue(job, settings: settings)
                } else {
                    let accounts = try select(body["selector"], settings: settings)
                    guard !accounts.isEmpty else { throw APIError.argument }
                    guard jobs.count < policy.maximumRetainedJobs, jobs.values.filter({ jobState($0) == "running" }).count < policy.maximumActiveJobs,
                          queue.count + accounts.count <= policy.maximumQueuedAccounts else { return .failure(429, "QUEUE_FULL", "刷新队列已满") }
                    guard refreshRate.take() else { return .failure(429, "RATE_LIMITED", "单次刷新请求过于频繁") }
                    let jobID = "job_" + UUID().uuidString.lowercased()
                    jobs[jobID] = Job(id: jobID, key: key, fingerprint: body)
                    keys[key] = jobID // Reserve before actor reentrancy can admit a duplicate.
                    let active = await coordinator.activeExecutions()
                    for account in accounts {
                        let workID: UUID
                        if let pending = works.first(where: { $0.value.account == account && $0.value.finishedAt == nil })?.key {
                            workID = pending
                            jobs[jobID]?.joinedWorkIDs.insert(pending)
                        } else {
                            workID = UUID()
                            if let execution = active[account] {
                                works[workID] = Work(account: account, action: "joined", state: execution.state, execution: execution.id)
                                Task { await self.watch(workID, executionID: execution.id, occupiesSlot: false) }
                            } else {
                                works[workID] = Work(account: account)
                                queue.append(workID)
                            }
                        }
                        jobs[jobID]?.workIDs.append(workID)
                    }
                    jobs[jobID]?.enrolling = false
                    pump()
                    data = jobValue(jobs[jobID]!, settings: settings)
                }
                if data["state"].string == "running" { status = 202 }
            case ("GET", let route) where route.hasPrefix("/v1/refresh-jobs/"):
                _ = try body.fields([])
                let id = String(route.dropFirst("/v1/refresh-jobs/".count))
                guard let job = jobs[id] else { return .failure(404, "JOB_NOT_FOUND", "任务不存在、已过期或 CapBar 已重启") }
                data = jobValue(job, settings: settings)
            case ("POST", "/v1/usage/query"), ("POST", "/v1/statistics/query"), ("POST", "/v1/records/query"):
                let accounts: [AccountID]
                var contributions = false
                var individual = false
                if path == "/v1/usage/query" {
                    _ = try body.fields(["target", "include_contributions"], required: ["target"])
                    let target = try body["target"].fields(["account_id", "provider"])
                    guard target.count == 1 else { throw APIError.argument }
                    if let id = target["account_id"]?.string {
                        accounts = try select(.object(["account_ids": .array([.string(id)])]), settings: settings)
                        individual = true
                    } else { accounts = try providerAccounts(body["target"], settings: settings) }
                    if let option = body.object?["include_contributions"] {
                        guard let value = option.bool, !individual else { throw APIError.argument }
                        contributions = value
                    }
                } else {
                    _ = try body.fields(["provider"], required: ["provider"])
                    accounts = try providerAccounts(body, settings: settings)
                }
                let records = await coordinator.state()
                data = try await analytics.query(path: path, accounts: accounts, settings: settings, records: records,
                    ids: Dictionary(uniqueKeysWithValues: accounts.map { ($0, registry.id($0)) }),
                    individual: individual, contributions: contributions)
            default: return .failure(404, "NOT_FOUND", "未开放此操作")
            }
            // Revocation applies even if an analytics query yielded while computing.
            guard (try await settingsStore.loadOrSeed()).externalAccess.enabled,
                  ExternalCredentials.matches(supplied, token) else { return .failure(401, "UNAUTHENTICATED", "访问已关闭或密钥已更新") }
            return ExternalResponse(status: status, value: .object([
                "api_version": .string("v1"), "request_id": .string("req_" + UUID().uuidString),
                "generated_at": .date(Date()), "data": data, "warnings": .array([])
            ]))
        } catch let error as APIError { return .failure(error.status, error.code, error.message) }
        catch { return .failure(500, "INTERNAL_ERROR", "无法读取或保存本地数据") }
    }

    func providerAccounts(_ body: APIValue, settings: UserSettings, optional: Bool = false) throws -> [AccountID] {
        if body.object?["provider"] == nil && optional { return settings.accounts }
        guard let raw = body["provider"].string, let provider = Provider(rawValue: raw) else { throw APIError.argument }
        return settings.accounts.filter { $0.provider == provider }
    }

    func select(_ value: APIValue, settings: UserSettings) throws -> [AccountID] {
        let fields = try value.fields(["all", "provider", "account_ids"])
        guard fields.count == 1 else { throw APIError.argument }
        let result: [AccountID]
        if fields["all"] != nil {
            guard value["all"].bool == true else { throw APIError.argument }
            result = settings.accounts
        } else if fields["provider"] != nil { result = try providerAccounts(value, settings: settings) }
        else {
            guard let ids = value["account_ids"].array, !ids.isEmpty, ids.count <= 200,
                  ids.allSatisfy({ $0.string != nil }) else { throw APIError.argument }
            let wanted = Set(ids.compactMap(\.string))
            result = settings.accounts.filter { wanted.contains(registry.id($0)) }
            guard result.count == wanted.count else { throw APIError(status: 404, code: "ACCOUNT_NOT_FOUND", message: "账号不存在") }
        }
        guard result.count <= 200 else { throw APIError.argument }
        return result
    }

    static func tier(_ account: AccountID, settings: UserSettings, records: [AccountID: AccountRecord]) -> UsagePlanTier? {
        settings.planOverrides.first { $0.account == account }?.tier
            ?? UsagePlanTier.detect(provider: account.provider, rawPlan: records[account]?.snapshot?.identity.plan)
    }
    func refreshState(_ account: AccountID) async -> String {
        if let execution = await coordinator.activeExecution(account) { return execution.state }
        return works.values.contains { $0.account == account && $0.finishedAt == nil } ? "queued" : "idle"
    }
    func quota(_ account: AccountID, record: AccountRecord?) async -> APIValue {
        .object([
            "account_id": .string(registry.id(account)), "provider": .string(account.provider.rawValue),
            "captured_at": .date(record?.snapshot?.capturedAt),
            "age_seconds": .numeric(record?.snapshot.map { max(0, Date().timeIntervalSince($0.capturedAt)) }),
            "last_attempt_at": .date(record?.lastAttemptAt), "refresh_state": .string(await refreshState(account)),
            "last_error": record?.lastError.map { .object(["code": .string("PROBE_OR_SAVE_FAILED"), "message": .string($0)]) } ?? .null,
            "windows": .array(record?.snapshot?.windows.map { window in .object([
                "kind": .string(window.kind == .fiveHour ? "five_hour" : "seven_day"),
                "remaining_percent": .number(window.remainingPercent), "used_percent": .number(100 - window.remainingPercent),
                "resets_at": .date(window.resetsAt)
            ]) } ?? [])
        ])
    }

    func pump() {
        while running < policy.maximumConcurrentProbes, !queue.isEmpty {
            let id = queue.removeFirst()
            running += 1
            Task { await self.start(id) }
        }
    }
    func start(_ id: UUID) async {
        guard let work = works[id] else { running -= 1; pump(); return }
        do {
            let settings = try await settingsStore.loadOrSeed()
            guard settings.externalAccess.enabled, settings.externalAccess.allowOneShotRefresh,
                  settings.accounts.contains(work.account) else {
                works[id]?.state = "skipped"; works[id]?.error = "刷新权限已关闭或账号已移除"; works[id]?.finishedAt = Date()
                running -= 1; pump(); return
            }
            // A UI/scheduled run may have finished while this work was queued.
            // Reuse that exact run rather than opening another session after it.
            if let recent = await coordinator.latestExecution(work.account, since: work.enqueuedAt) {
                works[id]?.execution = recent.id; works[id]?.action = "joined"
                await watch(id, executionID: recent.id, occupiesSlot: true)
                return
            }
            let joined = await coordinator.joinOrRefresh(work.account, recordHistory: settings.usageStatisticsEnabled,
                planTierOverride: settings.planOverrides.first { $0.account == work.account }?.tier)
            guard let joined else { throw APIError(status: 500, code: "REFRESH_FAILED", message: "无法开始刷新") }
            works[id]?.execution = joined.0
            works[id]?.action = joined.1 ? "started" : "joined"
            await watch(id, executionID: joined.0, occupiesSlot: true)
        } catch {
            works[id]?.state = "failed"; works[id]?.error = "无法开始刷新"; works[id]?.finishedAt = Date()
            running -= 1; pump()
        }
    }
    func watch(_ id: UUID, executionID: UUID, occupiesSlot: Bool) async {
        while let execution = await coordinator.execution(executionID) {
            works[id]?.state = execution.state
            works[id]?.result = execution
            if execution.isFinished { works[id]?.finishedAt = execution.finishedAt; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if works[id]?.finishedAt == nil {
            works[id]?.state = "interrupted"; works[id]?.finishedAt = Date()
        }
        if occupiesSlot { running -= 1; pump() }
    }
    func jobState(_ job: Job) -> String {
        let items = job.workIDs.compactMap { works[$0] }
        if job.enrolling || items.contains(where: { $0.finishedAt == nil }) { return "running" }
        if items.contains(where: { $0.state == "interrupted" }) { return "interrupted" }
        let failures = items.filter { $0.state == "failed" }.count
        return failures == 0 ? "completed" : failures == items.count ? "failed" : "partial_failure"
    }
    func jobValue(_ job: Job, settings: UserSettings) -> APIValue {
        let items = job.workIDs.compactMap { works[$0] }
        return .object([
            "job_id": .string(job.id), "state": .string(jobState(job)), "created_at": .date(job.createdAt),
            "finished_at": jobState(job) == "running" ? .null : .date(items.compactMap(\.finishedAt).max()),
            "items": .array(items.filter { settings.accounts.contains($0.account) }.map { work in .object([
                "account_id": .string(registry.id(work.account)), "action": .string(job.joinedWorkIDs.contains(where: { works[$0]?.account == work.account }) ? "joined" : work.action), "state": .string(work.state),
                "attempt": .number(Double(work.result?.attempt ?? 0)), "created_at": .date(work.result?.startedAt),
                "finished_at": .date(work.finishedAt), "captured_at": .date(work.result?.record?.snapshot?.capturedAt),
                "history_write": .string(work.result?.historyWrite ?? "not_requested"),
                "error": .text(work.error ?? work.result?.record?.lastError)
            ]) })
        ])
    }
    func pruneJobs() {
        for (id, job) in jobs where jobState(job) != "running" {
            let end = job.workIDs.compactMap { works[$0]?.finishedAt }.max() ?? job.createdAt
            if Date().timeIntervalSince(end) > policy.jobRetentionSeconds { jobs.removeValue(forKey: id); keys.removeValue(forKey: job.key) }
        }
        let referenced = Set(jobs.values.flatMap(\.workIDs))
        works = works.filter { referenced.contains($0.key) || $0.value.finishedAt == nil }
    }
}

extension UsagePlanTier {
    var apiName: String {
        switch self {
        case .claudePro: "claude_pro"
        case .claudeMax5: "claude_max_5x"
        case .claudeMax20: "claude_max_20x"
        case .claudeTeamStandard: "claude_team_standard"
        case .claudeTeamPremium: "claude_team_premium"
        case .codexPlus: "codex_plus"
        case .codexPro5: "codex_pro_5x"
        case .codexPro20: "codex_pro_20x"
        }
    }
}
