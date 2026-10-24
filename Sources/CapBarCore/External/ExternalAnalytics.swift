import Foundation

actor ExternalAnalytics {
    let history: UsageHistoryStore
    private var cache: [String: APIValue] = [:]
    private var active: String?
    private var failed: Set<String> = []
    init(history: UsageHistoryStore) { self.history = history }

    func query(path: String, accounts: [AccountID], settings: UserSettings, records: [AccountID: AccountRecord],
               ids: [AccountID: String], individual: Bool, contributions: Bool) async throws -> APIValue {
        let now = Date(), calendar = Calendar.current
        let hours = max(2, settings.samplingIntervalHours)
        let revision = try await history.revisionSignature(accounts: accounts)
        let planKey = accounts.map { ids[$0]! + ":" + (ExternalService.tier($0, settings: settings, records: records)?.rawValue ?? "unknown") }.joined(separator: ",")
        let key = "\(path)|\(planKey)|\(revision)|\(floor(now.timeIntervalSince1970 / Double(hours * 3600)))|\(calendar.startOfDay(for: now))|\(calendar.timeZone.identifier)|\(individual)|\(contributions)|\(settings.usageStatisticsEnabled)"
        if let cached = cache[key] { return cached }
        if active == nil {
            active = key
            failed.remove(key)
            Task {
                do {
                    let result = try await self.calculate(path: path, accounts: accounts, settings: settings, records: records,
                        ids: ids, individual: individual, contributions: contributions, now: now, calendar: calendar)
                    if self.cache.count >= 8 { self.cache.removeAll() }
                    self.cache[key] = result
                } catch { self.failed.insert(key) }
                self.active = nil
            }
        }
        guard active == key else { throw APIError(status: 503, code: "ANALYTICS_BUSY", message: "统计正在计算，请稍后重试") }
        for _ in 0..<100 {
            if let result = cache[key] { return result }
            if failed.contains(key) { throw APIError(status: 500, code: "INTERNAL_ERROR", message: "无法读取历史数据") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw APIError(status: 503, code: "ANALYTICS_BUSY", message: "统计正在计算，请稍后重试")
    }

    private func calculate(path: String, accounts: [AccountID], settings: UserSettings, records: [AccountID: AccountRecord],
                           ids: [AccountID: String], individual: Bool, contributions: Bool, now: Date, calendar: Calendar) async throws -> APIValue {
        let hours = max(2, settings.samplingIntervalHours), seconds = Double(hours * 3600)
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / seconds) * seconds)
        let start = end.addingTimeInterval(-7 * 86400)
        let tiers = accounts.map { ExternalService.tier($0, settings: settings, records: records) }
        let bounds = try await history.sampleBounds(accounts: accounts)
        var result: [String: APIValue] = [
            "availability": .string(bounds.0 == nil ? "no_history" : "available"),
            "collection_enabled": .bool(settings.usageStatisticsEnabled),
            "time_zone": .string(calendar.timeZone.identifier),
            "account_ids": .array(accounts.map { .string(ids[$0]!) }),
            "target": individual ? .object(["account_id": .string(ids[accounts[0]]!)]) : .object(["provider": .text(accounts.first?.provider.rawValue)]),
            "range": .object(["starts_at": .date(start), "ends_at": .date(end), "time_zone": .string(calendar.timeZone.identifier), "bin_hours": .number(Double(hours))]),
            "unit": .string(individual ? "account_weekly_quota_percent" : "baseline_weekly_quota_percent"),
            "baseline": .null
        ]
        if !individual, bounds.0 != nil, tiers.contains(where: { $0 == nil }) {
            result["availability"] = .string("calibration_required")
            result["uncalibrated_account_ids"] = .array(accounts.enumerated().filter { tiers[$0.offset] == nil }.map { .string(ids[$0.element]!) })
            return .object(result)
        }
        if !individual, let account = accounts.first, let baseline = tiers.first ?? nil {
            result["baseline"] = .object(["account_id": .string(ids[account]!), "plan_tier": .string(baseline.apiName), "capacity_factor": .number(baseline.capacityFactor), "estimated": .bool(true)])
        }
        if path == "/v1/records/query" {
            let calibrated = accounts.enumerated().compactMap { index, account in tiers[index].map { HistoricalAccount(account: account, tier: $0) } }
            let record = calibrated.count == accounts.count ? try await history.historicalStatistics(accounts: calibrated, intervalHours: settings.samplingIntervalHours, calendar: calendar, now: now)?.statistics : nil
            result["first_sample_at"] = .date(bounds.0)
            result["completed_before"] = .date(calendar.startOfDay(for: now))
            result["missing_policy"] = .string("zero_for_day_and_seven_day_totals")
            result["highest_seven_days"] = historical(record?.highSevenDays, calendar: calendar)
            result["lowest_seven_days"] = historical(record?.lowSevenDays, calendar: calendar)
            result["highest_day"] = historical(record?.highDay, calendar: calendar)
            result["highest_interval"] = historical(record?.highInterval, calendar: calendar)
            return .object(result)
        }
        var series: [UsageTrendSeries] = []
        for account in accounts {
            let samples = try await history.samples(account: account,
                from: start.addingTimeInterval(-Double(settings.samplingIntervalHours * 3600) - 900), through: now)
            series.append(UsageTrendCalculator.calculate(samples: samples, intervalHours: settings.samplingIntervalHours, endingAt: now))
        }
        let overview = ProviderTrendOverview.build(accounts.enumerated().map { index, account in
            TrendOverviewAccount(label: ids[account]!, tier: tiers[index], series: series[index])
        })
        let selected = individual ? series.first : overview.series
        let points = selected?.points ?? []
        result["coverage"] = .object([
            "valid_bins": .number(Double(points.filter { $0.usedPercent != nil }.count)), "expected_bins": .number(Double(168 / hours)),
            "first_sample_at": .date(bounds.0), "last_sample_at": .date(bounds.1)
        ])
        if path == "/v1/statistics/query" {
            let stats = overview.statistics(calendar: calendar)
            result["observed_total_percent"] = .numeric(stats?.observedTotal)
            result["maximum"] = stats?.peak.map { interval($0.value, end: $0.endAt, seconds: seconds) } ?? .null
            result["minimum_percent"] = .numeric(stats?.minimum)
            result["average_percent"] = .numeric(stats?.average)
            result["leading_account"] = stats?.leader.map { .object([
                "account_id": .string($0.label), "equivalent_usage_percent": .number($0.equivalentPercent), "share_percent": .number($0.sharePercent)
            ]) } ?? .null
            result["high_usage_period"] = period(stats?.highUsagePeriod, calendar: calendar)
            result["low_usage_period"] = period(stats?.lowUsagePeriod, calendar: calendar)
            result["usage_periods_uniform"] = .bool(stats?.usagePeriodsAreUniform ?? false)
            result["recent_24_hours"] = window(Array(points.suffix(24 / hours)), expected: 24 / hours)
            result["previous_24_hours"] = window(Array(points.dropLast(24 / hours).suffix(24 / hours)), expected: 24 / hours)
            result["change_percent"] = .numeric(stats?.changePercent)
            result["latest_observed_interval"] = overview.latestObservedPoint.flatMap { point in point.usedPercent.map { interval($0, end: point.endAt, seconds: seconds) } } ?? .null
        } else {
            result["points"] = .array(points.map { point in
                var value = interval(point.usedPercent, end: point.endAt, seconds: seconds).object!
                if individual {
                    value["remaining_percent"] = .numeric(point.remainingPercent)
                    value["crosses_reset"] = .bool(point.crossesReset)
                    value["estimated"] = .bool(point.isEstimated || point.crossesReset)
                } else {
                    let shares = overview.contributions(at: point.endAt) ?? []
                    value["observed_accounts"] = .number(Double(shares.count))
                    value["expected_accounts"] = .number(Double(accounts.count))
                    value["estimated"] = .bool(true)
                    if contributions {
                        value["contributions"] = .array(shares.map { share in .object([
                            "account_id": .string(ids[accounts[share.accountIndex]]!),
                            "raw_usage_percent": .numeric(series[share.accountIndex].points.first { $0.endAt == point.endAt }?.usedPercent),
                            "equivalent_usage_percent": .number(share.equivalentPercent)
                        ]) })
                    }
                }
                return .object(value)
            })
        }
        return .object(result)
    }
    private func interval(_ amount: Double?, end: Date, seconds: Double) -> APIValue {
        .object(["starts_at": .date(end.addingTimeInterval(-seconds)), "ends_at": .date(end), "usage_percent": .numeric(amount)])
    }
    private func window(_ points: [UsageTrendPoint], expected: Int) -> APIValue {
        let valid = points.compactMap(\.usedPercent)
        return .object(["usage_percent": .numeric(valid.isEmpty ? nil : valid.reduce(0, +)), "valid_bins": .number(Double(valid.count)), "expected_bins": .number(Double(expected))])
    }
    private func period(_ period: TrendUsagePeriod?, calendar: Calendar) -> APIValue {
        period.map { .object(["start_hour": .number(Double($0.startHour)), "end_hour": .number(Double($0.endHour)), "time_zone": .string(calendar.timeZone.identifier), "estimated": .bool(true)]) } ?? .null
    }
    private func historical(_ record: HistoricalUsageRecord?, calendar: Calendar) -> APIValue {
        guard let record else { return .null }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return .object([
            "usage_percent": .number(record.usedPercent), "starts_at": .date(record.startsAt), "ends_at": .date(record.endsAt),
            "start_date": .string(formatter.string(from: record.startsAt)),
            "end_date_inclusive": .string(formatter.string(from: record.endsAt.addingTimeInterval(-0.001)))
        ])
    }
}
