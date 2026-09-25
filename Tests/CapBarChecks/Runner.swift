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

        if filter == nil || filter == "ModelTests" { runModelChecks() }
        if filter == nil || filter == "StorageTests" { await runStorageChecks() }
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
        if filter == nil || filter == "ViewModelTests" { await runViewModelChecks() }
        if checksRun == 0 {
            fputs("No checks matched \(filter ?? "all")\n", stderr)
            exit(2)
        }
        print("\(checksRun) checks, \(checksFailed) failures")
        if checksFailed != 0 { exit(1) }
    }
}
