import Foundation
@testable import CapBarCore

@MainActor func runModelChecks() {
    let tilde = AccountID(provider: .claude, directory: "~/.claude")
    let absolute = AccountID(provider: .claude, directory: NSHomeDirectory() + "/.claude")
    check(tilde == absolute, "tilde and absolute spelling must identify the same account")

    let first = AccountID(provider: .claude, directory: "~/.claude-first")
    let second = AccountID(provider: .claude, directory: "~/.claude-second")
    check(first != second, "same provider with different directories must remain separate")
    check(first != AccountID(provider: .codex, directory: "~/.claude-first"), "provider is part of account identity")

    checkThrows("negative percentage") { _ = try QuotaWindow(kind: .fiveHour, remainingPercent: -1, resetsAt: nil) }
    checkThrows("non-finite percentage") { _ = try QuotaWindow(kind: .fiveHour, remainingPercent: .infinity, resetsAt: nil) }
    do {
        let full = try QuotaWindow(kind: .sevenDay, remainingPercent: 100, resetsAt: nil)
        check(full.remainingPercent == 100, "100% remaining is valid")
    } catch {
        check(false, "100% remaining must be accepted: \(error)")
    }

    let invalid = Data(#"{"maxAttempts":0,"attemptTimeoutSeconds":45,"retryDelayMinSeconds":20,"retryDelayMaxSeconds":10}"#.utf8)
    checkThrows("invalid policy") { _ = try JSONDecoder().decode(ProbePolicy.self, from: invalid) }
    do {
        let policy = try ProbePolicy.bundled()
        check(policy.maxAttempts == 3, "bundled policy should allow 3 attempts")
        check(policy.attemptTimeoutSeconds == 45, "bundled attempt timeout should be 45 seconds")
        check(policy.retryDelayMinSeconds == 10, "bundled jitter starts at 10 seconds")
        check(policy.retryDelayMaxSeconds == 20, "bundled jitter ends at 20 seconds")
    } catch {
        check(false, "bundled policy must load: \(error)")
    }
}
