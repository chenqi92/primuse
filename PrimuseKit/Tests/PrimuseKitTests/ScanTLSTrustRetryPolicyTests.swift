import Foundation
import Testing
@testable import PrimuseKit

@Suite("Scan TLS trust retry policy")
struct ScanTLSTrustRetryPolicyTests {
    @Test("The first trusted failure may restart the scan")
    func allowsFirstRetry() {
        #expect(ScanTLSTrustRetryPolicy.shouldRetry(afterTrustedRetries: 0))
    }

    @Test("A second trusted failure stops the restart loop")
    func stopsAfterMaximum() {
        #expect(!ScanTLSTrustRetryPolicy.shouldRetry(afterTrustedRetries: 1))
        #expect(!ScanTLSTrustRetryPolicy.shouldRetry(afterTrustedRetries: 2))
        #expect(!ScanTLSTrustRetryPolicy.shouldRetry(
            afterTrustedRetries: ScanTLSTrustRetryPolicy.maximumAutomaticRetries
        ))
    }

    @Test("A negative count behaves like a fresh scan")
    func treatsNegativeAsFresh() {
        #expect(ScanTLSTrustRetryPolicy.shouldRetry(afterTrustedRetries: -1))
    }
}
