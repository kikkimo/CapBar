import Foundation
@testable import CapBarCore

private actor RetryProbe {
    var calls = 0
    func failTwice() throws -> Int {
        calls += 1
        if calls < 3 { throw ProbeFailure.transient("network") }
        return calls
    }
    func alwaysPermanent() throws -> Int {
        calls += 1
        throw ProbeFailure.permanent("not logged in")
    }
}

private actor DelayLog {
    var delays: [Double] = []
    func append(_ delay: Double) { delays.append(delay) }
}

@MainActor func runRetryRunnerChecks() async {
    let policy = ProbePolicy(maxAttempts: 3, attemptTimeoutSeconds: 45, retryDelayMinSeconds: 10, retryDelayMaxSeconds: 20)
    let probe = RetryProbe()
    let delays = DelayLog()
    let runner = RetryRunner(policy: policy, pause: { await delays.append($0) }, chooseDelay: { range in range.lowerBound + 3 })
    do {
        let value = try await runner.run { try await probe.failTwice() }
        check(value == 3, "third transient attempt can succeed")
        check(await probe.calls == 3, "at most three attempts including first")
        let recorded = await delays.delays
        check(recorded == [13, 13], "only two retry waits occur within configured jitter range")
    } catch {
        check(false, "transient retries should succeed: \(error)")
    }

    let permanent = RetryProbe()
    do {
        _ = try await runner.run { try await permanent.alwaysPermanent() }
        check(false, "permanent error must propagate")
    } catch {
        check(await permanent.calls == 1, "permanent error does not retry")
    }

    let short = ProbePolicy(maxAttempts: 1, attemptTimeoutSeconds: 0.02, retryDelayMinSeconds: 0, retryDelayMaxSeconds: 0)
    let timeoutRunner = RetryRunner(policy: short)
    do {
        _ = try await timeoutRunner.run {
            try await Task.sleep(for: .seconds(5))
            return 1
        }
        check(false, "attempt timeout must interrupt a sleeping provider")
    } catch {
        check(true, "attempt timeout interrupts the provider")
    }
}
