import Testing
@testable import PrimuseKit

@Suite("Offline download commit policy")
struct OfflineDownloadCommitPolicyTests {
    @Test("A finished install publishes the artifact")
    func finishedInstallCommits() {
        #expect(OfflineDownloadCommitPolicy.commitsInstalledArtifact(
            isCancelled: false,
            installSucceeded: true
        ) == .commit)
    }

    @Test("A cancellation observed after the install publishes nothing")
    func cancelledAfterInstallReportsCancelled() {
        #expect(OfflineDownloadCommitPolicy.commitsInstalledArtifact(
            isCancelled: true,
            installSucceeded: true
        ) == .reportCancelled)
        #expect(OfflineDownloadCommitPolicy.commitsInstalledArtifact(
            isCancelled: true,
            installSucceeded: false
        ) == .reportCancelled)
        #expect(OfflineDownloadCommitPolicy.commitsInstalledArtifact(
            isCancelled: false,
            installSucceeded: false
        ) == .reportCancelled)
    }

    @Test("A cancelled transfer never reaches a joiner's pin")
    func joinerOnlyPinsCompletedTransfers() {
        let cancelled = OfflineDownloadCommitPolicy.commitsInstalledArtifact(
            isCancelled: true,
            installSucceeded: true
        )
        #expect(OfflineDownloadCommitPolicy.joinerPinsResult(
            resultIsCompleted: cancelled == .commit,
            waiterIsCancelled: false
        ) == false)
        #expect(OfflineDownloadCommitPolicy.joinerPinsResult(
            resultIsCompleted: true,
            waiterIsCancelled: true
        ) == false)
        #expect(OfflineDownloadCommitPolicy.joinerPinsResult(
            resultIsCompleted: false,
            waiterIsCancelled: false
        ) == false)
        #expect(OfflineDownloadCommitPolicy.joinerPinsResult(
            resultIsCompleted: true,
            waiterIsCancelled: false
        ))
    }
}
