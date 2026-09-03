import XCTest
@testable import Primuse

final class AudioCacheSyncPolicyTests: XCTestCase {
    func testCacheFileNameRejectsTraversalAndControlCharacters() {
        XCTAssertTrue(AudioCacheSyncPolicy.isSafeCacheFileName("2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("../2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("folder/2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("folder\\2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("bad\u{0}name.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName(".."))
    }

    func testTransferredByteCountMustMatchCatalogTolerance() {
        let catalog: Int64 = 100_000
        XCTAssertTrue(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: catalog,
            catalogByteCount: catalog
        ))
        XCTAssertTrue(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 95_000,
            catalogByteCount: catalog
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 94_999,
            catalogByteCount: catalog
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: catalog + 4_097,
            catalogByteCount: catalog
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 0,
            catalogByteCount: catalog
        ))
    }

    func testUnknownCatalogSizeStillRequiresNonemptyFile() {
        XCTAssertTrue(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 1,
            catalogByteCount: 0
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 0,
            catalogByteCount: 0
        ))
    }

    func testItemIDUsesCanonicalCacheRelativePath() {
        XCTAssertEqual(
            AudioCacheSyncPolicy.itemID(
                sourceID: "source-id",
                cacheFileName: "hashed-name.m4a"
            ),
            "source-id/hashed-name.m4a"
        )
    }

    func testLimitedItemIDsKeepsDeterministicPrefix() {
        let itemIDs = ["one", "two", "three", "four"]

        XCTAssertEqual(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: 3),
            ["one", "two", "three"]
        )
        XCTAssertEqual(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: 10),
            itemIDs
        )
        XCTAssertEqual(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: nil),
            itemIDs
        )
        XCTAssertTrue(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: 0).isEmpty
        )
    }
}
