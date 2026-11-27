import Foundation

/// Deduplicates concurrent async work while keeping its required persistence
/// step inside the shared task. Every participant therefore observes the same
/// success or failure, including failures that happen after the remote work
/// itself has completed.
public actor PersistedTaskDeduplicator<Value: Sendable> {
    private var inFlight: (id: UUID, task: Task<Value, Error>)?

    public init() {}

    public func run(
        operation: @Sendable @escaping () async throws -> Value,
        persist: @Sendable @escaping (Value) async throws -> Void
    ) async throws -> Value {
        if let inFlight {
            return try await inFlight.task.value
        }

        let id = UUID()
        let task = Task<Value, Error> {
            let value = try await operation()
            try await persist(value)
            return value
        }
        inFlight = (id, task)

        do {
            let value = try await task.value
            clearInFlight(id: id)
            return value
        } catch {
            clearInFlight(id: id)
            throw error
        }
    }

    /// Retries only the durable write for a value whose remote operation has
    /// already succeeded. It deliberately shares `inFlight` with `run` so
    /// concurrent callers neither repeat the remote operation nor race the
    /// persistence retry.
    public func retryPersistence(
        of value: Value,
        persist: @Sendable @escaping (Value) async throws -> Void
    ) async throws -> Value {
        try await run(
            operation: { value },
            persist: persist
        )
    }

    private func clearInFlight(id: UUID) {
        if inFlight?.id == id {
            inFlight = nil
        }
    }
}
