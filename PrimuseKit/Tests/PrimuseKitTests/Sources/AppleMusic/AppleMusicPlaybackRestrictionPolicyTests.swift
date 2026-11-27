import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music playback restriction policy")
struct AppleMusicPlaybackRestrictionPolicyTests {
    @Test("Only a complete library read without catalog playback reclassifies rows")
    func decidesWhenToReclassify() {
        #expect(AppleMusicPlaybackRestrictionPolicy.update(
            syncMode: .authoritative, canPlayCatalogContent: false
        ) == .recompute)
        #expect(AppleMusicPlaybackRestrictionPolicy.update(
            syncMode: .authoritative, canPlayCatalogContent: true
        ) == .clear)
        #expect(AppleMusicPlaybackRestrictionPolicy.update(
            syncMode: .partialFallback, canPlayCatalogContent: false
        ) == .keep)
        #expect(AppleMusicPlaybackRestrictionPolicy.update(
            syncMode: .partialFallback, canPlayCatalogContent: true
        ) == .keep)
    }

    @Test("Only unprotected cloud items can be fixed by downloading them")
    func recognizesDownloadableCloudItems() {
        #expect(AppleMusicPlaybackRestrictionPolicy.isDownloadableCloudItem(
            isCloudItem: true, hasProtectedAsset: false
        ))
        #expect(!AppleMusicPlaybackRestrictionPolicy.isDownloadableCloudItem(
            isCloudItem: true, hasProtectedAsset: true
        ))
        #expect(!AppleMusicPlaybackRestrictionPolicy.isDownloadableCloudItem(
            isCloudItem: false, hasProtectedAsset: true
        ))
        #expect(!AppleMusicPlaybackRestrictionPolicy.isDownloadableCloudItem(
            isCloudItem: false, hasProtectedAsset: false
        ))
    }

    @Test("Rows the subscription gate would stop are restricted, local files are not")
    func classifiesBySubscriptionGate() {
        let gated: [AppleMusicPlaybackSource] = [.catalog, .catalogBackedUserLibrary, .unverifiedUserLibrary]
        for source in gated {
            #expect(AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(for: source))
            #expect(AppleMusicPlaybackRestrictionPolicy.restriction(
                for: source, isDownloadableCloudItem: true
            ) == .cloudOnly)
            #expect(AppleMusicPlaybackRestrictionPolicy.restriction(
                for: source, isDownloadableCloudItem: false
            ) == .subscriptionRequired)
        }
        #expect(AppleMusicPlaybackRestrictionPolicy.restriction(
            for: .subscriptionIndependentUserLibrary, isDownloadableCloudItem: false
        ) == nil)
        #expect(AppleMusicPlaybackRestrictionPolicy.restriction(
            for: .subscriptionIndependentUserLibrary, isDownloadableCloudItem: true
        ) == nil)
    }

    @Test("A restriction only applies while catalog playback is known to be unavailable")
    func followsSubscriptionState() {
        #expect(AppleMusicPlaybackRestrictionPolicy.activeRestriction(
            .cloudOnly, canPlayCatalogContent: false
        ) == .cloudOnly)
        #expect(AppleMusicPlaybackRestrictionPolicy.activeRestriction(
            .subscriptionRequired, canPlayCatalogContent: false
        ) == .subscriptionRequired)
        #expect(AppleMusicPlaybackRestrictionPolicy.activeRestriction(
            .cloudOnly, canPlayCatalogContent: true
        ) == nil)
        #expect(AppleMusicPlaybackRestrictionPolicy.activeRestriction(
            .cloudOnly, canPlayCatalogContent: nil
        ) == nil)
        #expect(AppleMusicPlaybackRestrictionPolicy.activeRestriction(
            nil, canPlayCatalogContent: false
        ) == nil)
    }

    @Test("A device library with a few cloud rows keeps every row and counts the restricted ones")
    func countsRestrictedLibraryRows() {
        // 661 rows: 649 readable local files, 9 purchased songs still in the
        // cloud, 3 protected Apple Music cloud rows.
        var restrictions: [String: AppleMusicPlaybackRestriction] = [:]
        var librarySongIDs = Set<String>()
        for index in 0..<661 {
            let id = "song-\(index)"
            librarySongIDs.insert(id)
            let source: AppleMusicPlaybackSource = index < 649
                ? .subscriptionIndependentUserLibrary
                : .unverifiedUserLibrary
            let isCloud = index >= 649
            let isProtected = index >= 658
            if let restriction = AppleMusicPlaybackRestrictionPolicy.restriction(
                for: source,
                isDownloadableCloudItem: AppleMusicPlaybackRestrictionPolicy.isDownloadableCloudItem(
                    isCloudItem: isCloud, hasProtectedAsset: isProtected
                )
            ) {
                restrictions[id] = restriction
            }
        }
        // A playlist-only catalog row is restricted but is not part of the library count.
        restrictions["playlist-only"] = .subscriptionRequired

        #expect(librarySongIDs.count == 661)
        #expect(AppleMusicPlaybackRestrictionPolicy.restrictedCount(restrictions, among: librarySongIDs) == 12)
        #expect(restrictions.values.filter { $0 == .cloudOnly }.count == 9)
        #expect(restrictions.values.filter { $0 == .subscriptionRequired }.count == 4)
        #expect(AppleMusicPlaybackRestrictionPolicy.restrictedCount([:], among: librarySongIDs) == 0)
    }
}
