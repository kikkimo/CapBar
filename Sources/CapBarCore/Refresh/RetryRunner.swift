import Foundation

enum ProbeFailure: Error, Sendable {
    case transient(String)
    case permanent(String)
}

struct RetryRunner: Sendable {
    let policy: ProbePolicy
    let pause: @Sendable (Double) async -> Void
    let chooseDelay: @Sendable (ClosedRange<Double>) -> Double

    init(
        policy: ProbePolicy,
        pause: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        chooseDelay: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.policy = policy
        self.pause = pause
        self.chooseDelay = chooseDelay
    }

    func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        for attempt in 1...policy.maxAttempts {
            try Task.checkCancellation()
            do {
                return try await attemptWithTimeout(operation)
            } catch ProbeFailure.permanent(let message) {
                throw ProbeFailure.permanent(message)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if attempt == policy.maxAttempts { throw error }
                let delay = chooseDelay(policy.retryDelayMinSeconds...policy.retryDelayMaxSeconds)
                await pause(min(max(delay, policy.retryDelayMinSeconds), policy.retryDelayMaxSeconds))
            }
        }
        throw ProbeFailure.transient("retry exhausted")
    }

    private func attemptWithTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(policy.attemptTimeoutSeconds))
                throw ProbeFailure.transient("attempt timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ProbeFailure.transient("no probe result")
            }
            return first
        }
    }
}
