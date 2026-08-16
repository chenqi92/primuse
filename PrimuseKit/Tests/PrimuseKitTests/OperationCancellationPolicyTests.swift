import Foundation
import Testing
@testable import PrimuseKit

struct OperationCancellationPolicyTests {
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
}
