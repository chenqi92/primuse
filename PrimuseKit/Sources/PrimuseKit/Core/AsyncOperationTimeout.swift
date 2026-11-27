import Foundation

/// Returns as soon as the operation, timeout, or caller cancellation wins.
/// Unlike a task-group race, this does not wait for a losing child whose
/// transport ignores Swift task cancellation.
public enum AsyncOperationTimeout {
    public static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = CancellableResultRace<Value>()
        let operationTask = Task<Void, Never> {
            do {
                _ = race.resolve(.success(try await operation()))
            } catch {
                _ = race.resolve(.failure(error))
            }
        }
        let timeoutTask = Task<Void, Never> {
            do {
                let nanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            if race.resolve(.failure(URLError(.timedOut))) {
                operationTask.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                if Task.isCancelled, race.cancel() {
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            if race.cancel() {
                operationTask.cancel()
                timeoutTask.cancel()
            }
        }
    }
}
