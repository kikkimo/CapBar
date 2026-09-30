import Foundation

enum TrendScope: String, CaseIterable, Sendable {
    case total
    case individual
}

enum UsagePlanTier: String, CaseIterable, Codable, Sendable {
    case claudePro, claudeMax5, claudeMax20, claudeTeamStandard, claudeTeamPremium
    case codexPlus, codexPro5, codexPro20

    var provider: Provider {
        switch self {
        case .claudePro, .claudeMax5, .claudeMax20, .claudeTeamStandard, .claudeTeamPremium: .claude
        case .codexPlus, .codexPro5, .codexPro20: .codex
        }
    }

    var displayName: String {
        switch self {
        case .claudePro: "Pro"
        case .claudeMax5: "Max 5x"
        case .claudeMax20: "Max 20x"
        case .claudeTeamStandard: "Team Standard"
        case .claudeTeamPremium: "Team Premium"
        case .codexPlus: "Plus"
        case .codexPro5: "Pro 5x"
        case .codexPro20: "Pro 20x"
        }
    }

    // Estimated seven-day capacities from the design proposal; not verified provider limits.
    var capacityFactor: Double {
        switch self {
        case .claudePro, .codexPlus: 1
        case .claudeMax5, .codexPro5: 5
        case .claudeMax20, .codexPro20: 20
        case .claudeTeamStandard: 1.25
        case .claudeTeamPremium: 6.25
        }
    }

    static func options(for provider: Provider) -> [Self] { allCases.filter { $0.provider == provider } }

    static func detect(provider: Provider, rawPlan: String?) -> Self? {
        guard let rawPlan else { return nil }
        let plan = rawPlan.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return switch (provider, plan) {
        case (.claude, "pro"): .claudePro
        case (.claude, "max 5x"), (.claude, "max 5 x"): .claudeMax5
        case (.claude, "max 20x"), (.claude, "max 20 x"): .claudeMax20
        case (.claude, "team standard"): .claudeTeamStandard
        case (.claude, "team premium"): .claudeTeamPremium
        case (.codex, "plus"): .codexPlus
        case (.codex, "pro 5x"), (.codex, "pro 5 x"): .codexPro5
        case (.codex, "pro 20x"), (.codex, "pro 20 x"): .codexPro20
        default: nil
        }
    }
}

struct UsagePlanOverride: Codable, Sendable {
    let account: AccountID
    let tier: UsagePlanTier
}

struct WeightedUsageTrend: Sendable {
    let series: UsageTrendSeries
    let capacity: Double
}

struct TrendOverviewAccount: Sendable {
    let tier: UsagePlanTier?
    let series: UsageTrendSeries?
}

struct ProviderTrendOverview: Sendable {
    let accountCount: Int
    let baselinePlan: UsagePlanTier?
    let uncalibratedCount: Int
    let pendingHistoryCount: Int
    let series: UsageTrendSeries?

    static func build(_ accounts: [TrendOverviewAccount]) -> Self {
        let baseline = accounts.first?.tier
        let uncalibrated = accounts.filter { $0.tier == nil || $0.tier?.provider != baseline?.provider }.count
        let pending = accounts.filter { $0.series == nil }.count
        guard uncalibrated == 0, pending == 0, let baseline else {
            return Self(accountCount: accounts.count, baselinePlan: baseline,
                        uncalibratedCount: uncalibrated, pendingHistoryCount: pending, series: nil)
        }
        let weighted = accounts.compactMap { account -> WeightedUsageTrend? in
            guard let tier = account.tier, let series = account.series else { return nil }
            return WeightedUsageTrend(series: series, capacity: tier.capacityFactor)
        }
        return Self(
            accountCount: accounts.count, baselinePlan: baseline, uncalibratedCount: 0,
            pendingHistoryCount: 0,
            series: UsageTrendAggregator.aggregate(weighted, baselineCapacity: baseline.capacityFactor)
        )
    }
}

enum UsageTrendAggregator {
    static func aggregate(_ inputs: [WeightedUsageTrend], baselineCapacity: Double) -> UsageTrendSeries? {
        guard let first = inputs.first, !first.series.points.isEmpty,
              baselineCapacity.isFinite, baselineCapacity > 0,
              inputs.allSatisfy({ $0.capacity.isFinite && $0.capacity > 0 && $0.series.binHours == first.series.binHours })
        else { return nil }

        let remaining = inputs.dropFirst().map { input in
            Dictionary(input.series.points.map { ($0.endAt, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        let points = first.series.points.map { point in
            let aligned: [UsageTrendPoint?] = [point] + remaining.map { $0[point.endAt] }
            let contributions = aligned.compactMap { $0 }
            let total: Double?
            if contributions.count == inputs.count,
               contributions.allSatisfy({ $0.usedPercent.map { $0.isFinite && $0 >= 0 } ?? false }) {
                let value = zip(contributions, inputs).reduce(0.0) { sum, pair in
                    sum + (pair.0.usedPercent ?? 0) * (pair.0.planTier?.capacityFactor ?? pair.1.capacity) / baselineCapacity
                }
                total = value.isFinite ? value : nil
            } else {
                total = nil
            }
            return UsageTrendPoint(
                endAt: point.endAt, usedPercent: total, remainingPercent: nil,
                crossesReset: false, isEstimated: false
            )
        }
        let maximum = max(10, ceil((points.compactMap(\.usedPercent).max() ?? 0) / 10) * 10)
        let ticks = Int(maximum) % 30 == 0
            ? [0, maximum / 3, maximum * 2 / 3, maximum]
            : [0, maximum / 2, maximum]
        return UsageTrendSeries(
            points: points, binHours: first.series.binHours, axisMaximum: maximum,
            axisTicks: ticks, sampleCount: inputs.reduce(0) { $0 + $1.series.sampleCount },
            nextSampleAt: inputs.compactMap { $0.series.nextSampleAt }.min()
        )
    }
}

enum UsageTrendColorScale {
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    static func range(for series: [UsageTrendSeries]) -> ClosedRange<Double>? {
        let values = series.flatMap(\.points).compactMap(\.usedPercent).filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        return minimum...maximum
    }

    static func fraction(_ value: Double, in range: ClosedRange<Double>?) -> Double {
        guard let range, value.isFinite, range.upperBound > range.lowerBound else { return 0.5 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    // Google Research Turbo polynomial approximation, copyright 2019 Google LLC (Apache-2.0).
    // Match the approved design's softened central 0.14–0.84 range.
    // https://www.research.google/blog/turbo-an-improved-rainbow-colormap-for-visualization/
    static func turboRGB(at fraction: Double) -> RGB {
        let position = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
        let x = 0.14 + position * 0.70
        let x2 = x * x, x3 = x2 * x, x4 = x3 * x, x5 = x4 * x
        let red = 0.13572138 + 4.61539260*x - 42.66032258*x2 + 132.13108234*x3 - 152.94239396*x4 + 59.28637943*x5
        let green = 0.09140261 + 2.19418839*x + 4.84296658*x2 - 14.18503333*x3 + 4.27729857*x4 + 2.82956604*x5
        let blue = 0.10667330 + 12.64194608*x - 60.58204836*x2 + 110.36276771*x3 - 89.90310912*x4 + 27.34824973*x5
        func soften(_ channel: Double) -> Double { min(1, max(0, channel)) * 0.82 + 0.18 * 0.47 }
        return RGB(red: soften(red), green: soften(green), blue: soften(blue))
    }
}
