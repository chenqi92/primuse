import Foundation
import Testing
@testable import PrimuseKit

@Suite("LAN staged transfer")
struct LANStagedTransferTests {
    private let key = Data(repeating: 7, count: 32)

    @Test("Pairing links without a version stay on the single-payload protocol")
    func legacyLinkDefaultsToVersionOne() throws {
        let url = try #require(URL(string: "primuse://pair?host=192.168.1.5&port=5000&k=BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc&code=123456"))
        let link = try #require(LANPairLink(url: url))
        #expect(link.protocolVersion == 1)
        #expect(!link.supportsStagedTransfer)
        #expect(!link.qrContent.contains("v="))
    }

    @Test("Staged pairing links round-trip their version through the QR content")
    func stagedLinkRoundTrips() throws {
        let link = LANPairLink(host: "192.168.1.5", port: 5000, key: key, pairCode: "123456",
                               protocolVersion: LANPairLink.stagedProtocolVersion)
        let url = try #require(URL(string: link.qrContent))
        let parsed = try #require(LANPairLink(url: url))
        #expect(parsed == link)
        #expect(parsed.supportsStagedTransfer)
        #expect(parsed.url(for: .library)?.absoluteString == "http://192.168.1.5:5000/v2/library")
        #expect(parsed.configURL?.absoluteString == "http://192.168.1.5:5000/config")
    }

    @Test("Stages resolve from their paths and send in declaration order")
    func stagePathsAndOrder() {
        for stage in LANTransferStage.allCases {
            #expect(LANTransferStage(path: stage.path) == stage)
        }
        #expect(LANTransferStage(path: "/config") == nil)
        #expect(LANTransferStage.sources < .library)
        #expect(LANTransferStage.library < .artwork)
        #expect(LANTransferStage.artwork < .finish)
    }

    @Test("Batch position headers accept only in-range positions")
    func batchPositionHeader() {
        let position = LANArtworkBatchPosition(header: "3/6")
        #expect(position?.index == 3)
        #expect(position?.count == 6)
        #expect(position?.headerValue == "3/6")
        #expect(LANArtworkBatchPosition(header: nil) == nil)
        #expect(LANArtworkBatchPosition(header: "0/6") == nil)
        #expect(LANArtworkBatchPosition(header: "7/6") == nil)
        #expect(LANArtworkBatchPosition(header: "3") == nil)
        #expect(LANArtworkBatchPosition(header: "a/b") == nil)
    }

    @Test("Stage payload completeness follows what each stage must carry")
    func stagePayloadCompleteness() {
        let bytes = Data([0x01])
        #expect(LANSyncPayload(sourcesGz: bytes, credentials: CredentialBundle()).isCompleteSourcesStage)
        #expect(!LANSyncPayload(sourcesGz: bytes).isCompleteSourcesStage)
        #expect(!LANSyncPayload(credentials: CredentialBundle()).isCompleteSourcesStage)
        #expect(LANSyncPayload(libraryGz: bytes, sourcesGz: bytes).isCompleteLibraryStage)
        #expect(!LANSyncPayload(libraryGz: bytes).isCompleteLibraryStage)
        #expect(!LANSyncPayload(libraryGz: Data(), sourcesGz: bytes).isCompleteLibraryStage)
    }

    @Test("Artwork batches stay under the byte limit and keep every cover with its references")
    func artworkBatchesSplitBySize() {
        let cached = [
            "a": Data(count: 400),
            "b": Data(count: 400),
            "c": Data(count: 400),
        ]
        let references = [
            "song-1.jpg": "a",
            "album/x.jpg": "a",
            "song-2.jpg": "b",
            "song-3.jpg": "c",
            "orphan.jpg": "missing",
        ]
        let batches = LANArtworkBatch.batches(
            customAssets: ["custom": Data(count: 300)],
            cachedAssets: cached,
            references: references,
            maximumRawBytes: 800
        )
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.rawByteCount <= 800 })
        #expect(batches[0].customAssets.keys.sorted() == ["custom"])
        #expect(batches[0].cachedAssets.keys.sorted() == ["a"])
        #expect(batches[0].references == ["song-1.jpg": "a", "album/x.jpg": "a"])
        #expect(batches[1].cachedAssets.keys.sorted() == ["b", "c"])
        let allReferences = batches.reduce(into: [String: String]()) { $0.merge($1.references) { a, _ in a } }
        #expect(allReferences["orphan.jpg"] == nil)
        #expect(allReferences.count == 4)
    }

    @Test("A cover larger than the limit travels alone, and unreferenced covers are dropped")
    func artworkBatchesHandleOversizeAndUnreferenced() {
        let batches = LANArtworkBatch.batches(
            customAssets: [:],
            cachedAssets: ["big": Data(count: 2_000), "small": Data(count: 10), "unused": Data(count: 10)],
            references: ["x.jpg": "big", "y.jpg": "small"],
            maximumRawBytes: 1_000
        )
        #expect(batches.count == 2)
        #expect(batches[0].cachedAssets.keys.sorted() == ["big"])
        #expect(batches[1].cachedAssets.keys.sorted() == ["small"])
        #expect(LANArtworkBatch.batches(customAssets: [:], cachedAssets: [:], references: [:],
                                        maximumRawBytes: 1_000).isEmpty)
    }

    @Test("Artwork batches survive the JSON round trip")
    func artworkBatchRoundTrip() throws {
        let batch = LANArtworkBatch(customAssets: ["c": Data([1, 2])], cachedAssets: ["a": Data([3])],
                                    references: ["song.jpg": "a"])
        let decoded = try #require(LANArtworkBatch.decode(try batch.jsonData()))
        #expect(decoded == batch)
    }

    @Test("Late progress for the current or an earlier request cannot overwrite the status")
    func receiveStatusIgnoresLateProgress() {
        let saving = LANReceiveStatus(phase: .saving, stage: .library, requestSerial: 4)
        #expect(saving.supersedes(progressSerial: 4))
        #expect(saving.supersedes(progressSerial: 3))
        #expect(!saving.supersedes(progressSerial: 5))

        let failed = LANReceiveStatus(phase: .failed, stage: .library, requestSerial: 4)
        #expect(failed.supersedes(progressSerial: 4))
        #expect(!failed.supersedes(progressSerial: 5))

        let receiving = LANReceiveStatus(phase: .receiving, stage: .artwork, batchIndex: 2, batchCount: 4,
                                         requestSerial: 6)
        #expect(!receiving.supersedes(progressSerial: 6))
        #expect(receiving.supersedes(progressSerial: 5))
    }

    @Test("Received fraction combines artwork batches")
    func receivedFraction() {
        #expect(LANReceiveStatus.receivedFraction(receivedBytes: 50, totalBytes: 100,
                                                  batchIndex: nil, batchCount: nil) == 0.5)
        #expect(LANReceiveStatus.receivedFraction(receivedBytes: 50, totalBytes: 100,
                                                  batchIndex: 3, batchCount: 4) == 0.625)
        #expect(LANReceiveStatus.receivedFraction(receivedBytes: 0, totalBytes: 0,
                                                  batchIndex: nil, batchCount: nil) == nil)
        #expect(LANReceiveStatus.receivedFraction(receivedBytes: 200, totalBytes: 100,
                                                  batchIndex: nil, batchCount: nil) == 1)
    }
}
