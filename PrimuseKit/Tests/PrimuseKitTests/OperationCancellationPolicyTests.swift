import Foundation
import Testing
@testable import PrimuseKit

struct OperationCancellationPolicyTests {
    private enum ProbeError: Error {
        case failed
    }

    private static func waitNonCooperatively(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test("Swift cancellation and task-backed URLSession cancellation are interruptions")
    func recognizesCancellationForms() {
        #expect(OperationCancellationPolicy.isCancellation(CancellationError()))
        #expect(OperationCancellationPolicy.isCancellation(NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        ), operationIsCancelled: true))
        #expect(OperationCancellationPolicy.isCancellation(
            URLError(.cancelled),
            operationIsCancelled: true
        ))
    }

    @Test("An SSL challenge rejection is not mistaken for task cancellation")
    func rejectsAmbiguousFoundationCancellationWithoutTaskCancellation() {
        #expect(!OperationCancellationPolicy.isCancellation(
            URLError(.cancelled),
            operationIsCancelled: false
        ))
    }

    @Test("Ordinary network failures remain failures")
    func rejectsOrdinaryFailures() {
        #expect(!OperationCancellationPolicy.isCancellation(URLError(.timedOut)))
        #expect(!OperationCancellationPolicy.isCancellation(URLError(.cannotConnectToHost)))
    }

    @Test("Hard timeout preserves success and operation failures")
    func hardTimeoutPreservesCompletedResults() async throws {
        let value = try await AsyncOperationTimeout.run(seconds: 1) { 42 }
        #expect(value == 42)

        await #expect(throws: ProbeError.self) {
            let _: Int = try await AsyncOperationTimeout.run(seconds: 1) {
                throw ProbeError.failed
            }
        }
    }

    @Test("Hard timeout returns without waiting for a non-cooperative operation")
    func hardTimeoutDoesNotJoinLosingOperation() async {
        let start = Date()
        do {
            _ = try await AsyncOperationTimeout.run(seconds: 0.1) {
                Self.waitNonCooperatively(for: 0.5)
                return 42
            }
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(Date().timeIntervalSince(start) < 0.4)
    }

    @Test("Caller cancellation resolves a pending timeout race")
    func hardTimeoutHonorsCallerCancellation() async {
        let task = Task<Int, any Error> {
            try await AsyncOperationTimeout.run(seconds: 5) {
                try await Task.sleep(for: .seconds(1))
                return 42
            }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
