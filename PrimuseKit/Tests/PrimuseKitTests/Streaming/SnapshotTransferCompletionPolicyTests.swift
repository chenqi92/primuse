import Foundation
import Testing
@testable import PrimuseKit

@Suite("Snapshot transfer completion")
struct SnapshotTransferCompletionPolicyTests {
    @Test("iCloud reports success only when every required transfer completes")
    func iCloudRequiresSnapshotAndCredentialCompletion() {
        #expect(SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: true,
            credentialOutcome: .succeeded
        ))
        #expect(SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: true,
            credentialOutcome: .skipped
        ))
        #expect(!SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: true,
            credentialOutcome: .failed
        ))
        #expect(!SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: false,
            credentialOutcome: .succeeded
        ))
    }

    @Test("LAN requires both a library snapshot and prepared credentials")
    func lanRequiresLibraryAndPreparedCredentials() {
        #expect(SnapshotTransferCompletionPolicy.canSendLAN(
            hasLibrarySnapshot: true,
            credentialOutcome: .succeeded
        ))
        #expect(!SnapshotTransferCompletionPolicy.canSendLAN(
            hasLibrarySnapshot: false,
            credentialOutcome: .succeeded
        ))
        #expect(!SnapshotTransferCompletionPolicy.canSendLAN(
            hasLibrarySnapshot: true,
            credentialOutcome: .skipped
        ))
        #expect(!SnapshotTransferCompletionPolicy.canSendLAN(
            hasLibrarySnapshot: true,
            credentialOutcome: .failed
        ))
    }

    @Test("LAN payload completeness rejects a missing or empty library")
    func lanPayloadRequiresNonemptyLibrary() {
        let credentials = CredentialBundle()
        #expect(LANSyncPayload(
            libraryGz: Data([0x01]),
            sourcesGz: Data([0x01]),
            credentials: credentials
        ).isCompleteForTransfer)
        #expect(!LANSyncPayload(libraryGz: Data([0x01]), credentials: credentials).isCompleteForTransfer)
        #expect(!LANSyncPayload(credentials: credentials).isCompleteForTransfer)
        #expect(!LANSyncPayload(
            libraryGz: Data(),
            credentials: credentials
        ).isCompleteForTransfer)
        #expect(!LANSyncPayload(
            libraryGz: Data([0x01])
        ).isCompleteForTransfer)
    }

    @Test("LAN artwork budget stays unchanged when the sealed body fits")
    func lanArtworkBudgetKeepsFittingPayload() {
        let limit = LANTransferSizePolicy.maximumSealedBytes
        #expect(LANTransferSizePolicy.reducedArtworkBudget(
            artworkBytes: 24 << 20,
            sealedBytes: limit
        ) == nil)
        #expect(LANTransferSizePolicy.reducedArtworkBudget(
            artworkBytes: 0,
            sealedBytes: limit + 1
        ) == nil)
    }

    @Test("LAN artwork budget shrinks enough for covers that cost 4/3 body bytes")
    func lanArtworkBudgetCoversExcess() {
        let limit = LANTransferSizePolicy.maximumSealedBytes
        for excess in [1, 64 << 10, 3 << 20, 5 << 20] {
            let artwork = 24 << 20
            let reduced = LANTransferSizePolicy.reducedArtworkBudget(
                artworkBytes: artwork,
                sealedBytes: limit + excess
            )
            #expect(reduced != nil)
            guard let reduced else { continue }
            #expect(reduced < artwork)
            #expect((artwork - reduced) * 4 / 3 > excess)
        }
    }

    @Test("LAN artwork budget drops covers when little would remain")
    func lanArtworkBudgetFallsBackToNoArtwork() {
        let limit = LANTransferSizePolicy.maximumSealedBytes
        let reduced = LANTransferSizePolicy.reducedArtworkBudget(
            artworkBytes: 2 << 20,
            sealedBytes: limit + (2 << 20)
        )
        #expect(reduced == 0)
    }

    @Test("Apple TV transfer failures expose stable diagnostic codes")
    func transferFailureDiagnosticCodes() {
        #expect(AppleTVTransferFailure.snapshotMissing.diagnosticCode == "TV-SNAPSHOT-MISSING")
        #expect(AppleTVTransferFailure.snapshotPreparationFailed.diagnosticCode == "TV-SNAPSHOT-PREPARE")
        #expect(AppleTVTransferFailure.localNetworkFailed(
            detail: "offline"
        ).diagnosticCode == "TV-LAN-CONNECTION")
        #expect(AppleTVTransferFailure.tvRejected(
            statusCode: 403
        ).diagnosticCode == "TV-HTTP-403")
    }

    @Test("Apple TV HTTP failures retain the actual status")
    func transferFailureHTTPStatusMessage() {
        let forbidden = AppleTVTransferFailure.tvRejected(statusCode: 403)
        let unexpected = AppleTVTransferFailure.tvRejected(statusCode: 429)
        #expect(forbidden.userFacingMessage.contains("403"))
        #expect(unexpected.userFacingMessage.contains("429"))
    }
}
