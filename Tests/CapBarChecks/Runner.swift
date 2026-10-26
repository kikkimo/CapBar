import Foundation
@testable import CapBarCore

@MainActor private(set) var checksRun = 0
@MainActor private(set) var checksFailed = 0

@MainActor func check(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    checksRun += 1
    if !condition {
        checksFailed += 1
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
    }
}

@MainActor func checkThrows(_ message: String, _ body: () throws -> Void) {
    checksRun += 1
    do {
        try body()
        checksFailed += 1
        fputs("FAIL expected error: \(message)\n", stderr)
    } catch {}
}

@main struct CheckRunner {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--render-token-usage") {
            do { try await renderTokenUsagePreview() }
            catch { fputs("Token preview failed: \(error)\n", stderr); exit(1) }
            return
        }
        if arguments.contains("--render-popover") {
            do { try await renderPopoverPreview() }
            catch { fputs("Popover preview failed: \(error)\n", stderr); exit(1) }
            return
        }
        let filter: String?
        if let index = arguments.firstIndex(of: "--filter"), arguments.indices.contains(index + 1) {
            filter = arguments[index + 1]
        } else {
            filter = nil
        }

        if filter == nil || filter == "ExternalIntegrationTests" { await runExternalIntegrationChecks() }
        if filter == nil || filter == "ExternalMCPTests" { runExternalMCPChecks() }
        if filter == nil || filter == "ExternalHTTPTests" { runExternalHTTPChecks() }
        if filter == nil || filter == "ExternalAccessTests" { await runExternalAccessChecks() }
        if filter == nil || filter == "TokenReportTests" { await runTokenReportChecks() }
        if filter == nil || filter == "TokenEdgeTests" { await runTokenEdgeChecks() }
        if filter == "TokenLiveTests" { await runTokenLiveChecks() }
        if filter == nil || filter == "TokenControllerTests" { await runTokenControllerChecks() }
        if filter == nil || filter == "TokenScannerTests" { await runTokenScannerChecks() }
        if filter == nil || filter == "TokenUsageTests" { await runTokenUsageChecks() }
        if filter == nil || filter == "ModelTests" { runModelChecks() }
        if filter == nil || filter == "StorageTests" { await runStorageChecks() }
        if filter == nil || filter == "UsageHistoryTests" { await runUsageHistoryChecks() }
        if filter == nil || filter == "UsageTrendTests" { runUsageTrendChecks() }
        if filter == nil || filter == "ProviderTrendStatisticsTests" { runProviderTrendStatisticsChecks() }
        if filter == nil || filter == "HistoricalTrendStatisticsTests" { runHistoricalTrendStatisticsChecks() }
        if filter == nil || filter == "UsageSamplingTests" { await runUsageSamplingChecks() }
        if filter == nil || filter == "UsageTrendChartTests" { runUsageTrendChartChecks() }
        if filter == nil || filter == "TimeLabelTests" { runTimeLabelChecks() }
        if filter == nil || filter == "RetryRunnerTests" { await runRetryRunnerChecks() }
        if filter == nil || filter == "RefreshCoordinatorTests" { await runRefreshCoordinatorChecks() }
        if filter == nil || filter == "CodexClientTests" { await runCodexClientChecks() }
        if filter == "CodexLiveTests" { await runCodexLiveChecks() }
        if filter == nil || filter == "ClaudeParsingTests" { runClaudeParsingChecks() }
        if filter == nil || filter == "ClaudeClientTests" { await runClaudeClientChecks() }
        if filter == "ClaudeLiveTests" { await runClaudeLiveChecks() }
        if filter == "AppIntegrationTests" { await runAppIntegrationChecks() }
        if filter == nil || filter == "PopoverModelTests" { runPopoverModelChecks() }
        if filter == nil || filter == "PopoverDismissalTests" { runPopoverDismissalChecks() }
        if filter == nil || filter == "StatusMenuTests" { runStatusMenuChecks() }
        if filter == nil || filter == "LaunchAtLoginTests" { runLaunchAtLoginChecks() }
        if filter == nil || filter == "ViewModelTests" { await runViewModelChecks() }
        if checksRun == 0 {
            fputs("No checks matched \(filter ?? "all")\n", stderr)
            exit(2)
        }
        print("\(checksRun) checks, \(checksFailed) failures")
        if checksFailed != 0 { exit(1) }
    }
}
