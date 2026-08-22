import Testing
@testable import PrimuseKit

@Suite("Remote directory recovery")
struct RemoteDirectoryRecoveryPolicyTests {
    @Test("A transient failure gets exactly one fresh-connection retry")
    func transientFailureIsBounded() {
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .retryableFailure,
            completedRetryAttempts: 0,
            emptyNeedsFreshConfirmation: false
        ) == .retryFreshConnection)
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .retryableFailure,
            completedRetryAttempts: 1,
            emptyNeedsFreshConfirmation: false
        ) == .fail)
    }

    @Test("Permanent failures never reconnect")
    func permanentFailureDoesNotRetry() {
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .permanentFailure,
            completedRetryAttempts: 0,
            emptyNeedsFreshConfirmation: true
        ) == .fail)
    }

    @Test("Ambiguous empty listings require one independent confirmation")
    func ambiguousEmptyIsConfirmedOnce() {
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .empty,
            completedRetryAttempts: 0,
            emptyNeedsFreshConfirmation: true
        ) == .retryFreshConnection)
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .empty,
            completedRetryAttempts: 1,
            emptyNeedsFreshConfirmation: true,
            previousAttemptWasEmpty: true
        ) == .accept)
    }

    @Test("An empty response after a failed first attempt is not authoritative")
    func emptyAfterFailureIsRejected() {
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .empty,
            completedRetryAttempts: 1,
            emptyNeedsFreshConfirmation: true,
            previousAttemptWasEmpty: false
        ) == .fail)
    }

    @Test("Protocol-validated empty listings remain valid")
    func validatedEmptyIsAccepted() {
        #expect(RemoteDirectoryRecoveryPolicy.decision(
            outcome: .empty,
            completedRetryAttempts: 0,
            emptyNeedsFreshConfirmation: false
        ) == .accept)
    }

    @Test("S3 requires a complete ListBucketResult envelope")
    func s3EnvelopeValidation() {
        #expect(S3ListResponseValidationPolicy.isValid(
            xmlParsed: true,
            sawListBucketResult: true,
            hasValidIsTruncatedMarker: true,
            isTruncated: false,
            hasContinuationToken: false
        ))
        #expect(!S3ListResponseValidationPolicy.isValid(
            xmlParsed: false,
            sawListBucketResult: true,
            hasValidIsTruncatedMarker: true,
            isTruncated: false,
            hasContinuationToken: false
        ))
        #expect(!S3ListResponseValidationPolicy.isValid(
            xmlParsed: true,
            sawListBucketResult: false,
            hasValidIsTruncatedMarker: true,
            isTruncated: false,
            hasContinuationToken: false
        ))
        #expect(!S3ListResponseValidationPolicy.isValid(
            xmlParsed: true,
            sawListBucketResult: true,
            hasValidIsTruncatedMarker: false,
            isTruncated: false,
            hasContinuationToken: false
        ))
        #expect(!S3ListResponseValidationPolicy.isValid(
            xmlParsed: true,
            sawListBucketResult: true,
            hasValidIsTruncatedMarker: true,
            isTruncated: true,
            hasContinuationToken: false
        ))
        #expect(S3ListResponseValidationPolicy.isValid(
            xmlParsed: true,
            sawListBucketResult: true,
            hasValidIsTruncatedMarker: true,
            isTruncated: true,
            hasContinuationToken: true
        ))
    }
}
