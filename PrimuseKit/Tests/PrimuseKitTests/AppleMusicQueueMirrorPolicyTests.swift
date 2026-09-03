import Testing
@testable import PrimuseKit

@Suite("Apple Music queue mirror policy")
struct AppleMusicQueueMirrorPolicyTests {
    @Test("Cancelled or superseded mirrors cannot replace a newer queue")
    func rejectsStaleMirrorSessions() {
        #expect(!AppleMusicQueueMirrorPolicy.isActiveSession(
            sessionGeneration: 4,
            activeGeneration: 5,
            isCancelled: false
        ))
        #expect(!AppleMusicQueueMirrorPolicy.isActiveSession(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: true
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 4,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 12
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: true,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 12
        ))
    }

    @Test("Mixed queues and transient empty snapshots remain Primuse-owned")
    func protectsCanonicalQueue() {
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: true,
            snapshotCount: 12
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 0
        ))
    }

    @Test("Only a current non-empty Apple-Music-only snapshot can apply")
    func acceptsCurrentMusicKitSnapshot() {
        #expect(AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 12
        ))
    }
}

@Suite("Apple Music queue ownership policy")
struct AppleMusicQueueOwnershipPolicyTests {
    @Test("Every explicit Primuse queue remains canonical")
    func keepsPureAndMixedQueuesPrimuseManaged() {
        #expect(AppleMusicQueueOwnershipPolicy.shouldUsePrimuseQueue(
            selectedQueueEntryMatches: true
        ))
        #expect(!AppleMusicQueueOwnershipPolicy.shouldUsePrimuseQueue(
            selectedQueueEntryMatches: false
        ))
    }
}

@Suite("Apple Music audio-session interruption policy")
struct AppleMusicAudioSessionInterruptionPolicyTests {
    @Test("Started MusicKit playback owns interruption recovery")
    func delegatesStartedPlaybackToMusicKit() {
        #expect(AppleMusicAudioSessionInterruptionPolicy.shouldDeferToSystemTransport(
            hasActivePlaybackRequest: true,
            requestIsPending: false
        ))
    }

    @Test("Pending requests and local playback keep existing handling")
    func keepsPendingAndLocalHandling() {
        #expect(!AppleMusicAudioSessionInterruptionPolicy.shouldDeferToSystemTransport(
            hasActivePlaybackRequest: true,
            requestIsPending: true
        ))
        #expect(!AppleMusicAudioSessionInterruptionPolicy.shouldDeferToSystemTransport(
            hasActivePlaybackRequest: false,
            requestIsPending: false
        ))
    }

    @Test("Only resumed clock progress clears end suppression")
    func clearsSuppressionAfterProgress() {
        #expect(AppleMusicAudioSessionInterruptionPolicy.shouldClearSuppression(
            isPlaying: true,
            madeProgress: true
        ))
        #expect(!AppleMusicAudioSessionInterruptionPolicy.shouldClearSuppression(
            isPlaying: true,
            madeProgress: false
        ))
        #expect(!AppleMusicAudioSessionInterruptionPolicy.shouldClearSuppression(
            isPlaying: false,
            madeProgress: true
        ))
    }
}

@Suite("Apple Music subscription gate policy")
struct AppleMusicSubscriptionGatePolicyTests {
    @Test("Catalog results require subscription capability")
    func gatesCatalogPlayback() {
        #expect(AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(for: .catalog))
    }

    @Test("Catalog-backed library songs retain the crash-prevention gate")
    func gatesCatalogBackedLibraryPlayback() {
        #expect(AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(
            for: .catalogBackedUserLibrary
        ))
    }

    @Test("Only confirmed library-only songs bypass the catalog gate")
    func allowsImportedLibraryPlaybackWithoutSubscription() {
        #expect(!AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(
            for: .subscriptionIndependentUserLibrary
        ))
    }
}

@Suite("Apple Music system queue policy")
struct AppleMusicSystemQueuePolicyTests {
    @Test("Imported library tracks keep continuous imported playback")
    func keepsImportedQueue() {
        let plan = AppleMusicSystemQueuePolicy.plan(
            startingItemID: "i.two",
            startingSource: .subscriptionIndependentUserLibrary,
            queuedItemIDs: ["i.one", "i.two", "i.three"],
            queuedSources: Array(
                repeating: .subscriptionIndependentUserLibrary,
                count: 3
            )
        )

        #expect(plan == AppleMusicSystemQueuePlan(
            retainedIndices: [0, 1, 2],
            startIndex: 1
        ))
    }

    @Test("Imported starts exclude catalog-backed queue entries")
    func filtersCatalogEntriesAfterImportedStart() {
        let plan = AppleMusicSystemQueuePolicy.plan(
            startingItemID: "i.imported-two",
            startingSource: .subscriptionIndependentUserLibrary,
            queuedItemIDs: ["i.imported-one", "i.imported-two", "i.catalog", "12345"],
            queuedSources: [
                .subscriptionIndependentUserLibrary,
                .subscriptionIndependentUserLibrary,
                .catalogBackedUserLibrary,
                .catalog,
            ]
        )

        #expect(plan == AppleMusicSystemQueuePlan(
            retainedIndices: [0, 1],
            startIndex: 1
        ))
    }

    @Test("Signed decimal local rows keep order while catalog rows are filtered")
    func filtersCatalogEntriesFromDecimalLocalQueue() {
        let plan = AppleMusicSystemQueuePolicy.plan(
            startingItemID: "-350135260054884126",
            startingSource: .subscriptionIndependentUserLibrary,
            queuedItemIDs: [
                "6867642289211602051",
                "catalog-123",
                "-350135260054884126",
                "i.catalog-backed",
            ],
            queuedSources: [
                .subscriptionIndependentUserLibrary,
                .catalog,
                .subscriptionIndependentUserLibrary,
                .catalogBackedUserLibrary,
            ]
        )

        #expect(plan == AppleMusicSystemQueuePlan(
            retainedIndices: [0, 2],
            startIndex: 1
        ))
    }

    @Test("Catalog and unverified starts retain the guarded queue")
    func guardedStartsRetainQueue() {
        for source in [
            AppleMusicPlaybackSource.catalog,
            .catalogBackedUserLibrary,
            .unverifiedUserLibrary,
        ] {
            let plan = AppleMusicSystemQueuePolicy.plan(
                startingItemID: "guarded",
                startingSource: source,
                queuedItemIDs: ["imported", "guarded", "catalog"],
                queuedSources: [
                    .subscriptionIndependentUserLibrary,
                    source,
                    .catalog,
                ]
            )

            #expect(plan == AppleMusicSystemQueuePlan(
                retainedIndices: [0, 1, 2],
                startIndex: 1
            ))
            #expect(AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(for: source))
        }
    }

    @Test("A stale queue without the requested item falls back to that item only")
    func rejectsQueueMissingStartingItem() {
        let plan = AppleMusicSystemQueuePolicy.plan(
            startingItemID: "i.requested",
            startingSource: .subscriptionIndependentUserLibrary,
            queuedItemIDs: ["i.stale", "catalog"],
            queuedSources: [.subscriptionIndependentUserLibrary, .catalog]
        )

        #expect(plan == nil)
    }
}

@Suite("Apple Music queue recovery policy")
struct AppleMusicQueueRecoveryPolicyTests {
    @Test("System-player failures retry only multi-item queues")
    func retriesOnlyMultiItemSystemQueues() {
        #expect(AppleMusicQueueRecoveryPolicy.shouldRetryWithStartingItemOnly(
            errorDomain: AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain,
            queueItemCount: 61
        ))
        #expect(!AppleMusicQueueRecoveryPolicy.shouldRetryWithStartingItemOnly(
            errorDomain: AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain,
            queueItemCount: 1
        ))
        #expect(!AppleMusicQueueRecoveryPolicy.shouldRetryWithStartingItemOnly(
            errorDomain: "NSURLErrorDomain",
            queueItemCount: 61
        ))
    }

    @Test("Error 2 is accepted only after the play command")
    func acceptsSpuriousErrorOnlyWhilePlaying() {
        #expect(AppleMusicQueueRecoveryPolicy.shouldTreatAsStarted(
            errorDomain: AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain,
            errorCode: 2,
            failedWhilePlaying: true
        ))
        #expect(!AppleMusicQueueRecoveryPolicy.shouldTreatAsStarted(
            errorDomain: AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain,
            errorCode: 2,
            failedWhilePlaying: false
        ))
        #expect(!AppleMusicQueueRecoveryPolicy.shouldTreatAsStarted(
            errorDomain: AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain,
            errorCode: 6,
            failedWhilePlaying: true
        ))
    }
}

@Suite("Apple Music playback source resolver")
struct AppleMusicPlaybackSourceResolverTests {
    @Test("A non-library identifier is a catalog result")
    func resolvesCatalogResult() {
        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "123456789",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: [],
            confirmedLibraryIDs: []
        ) == .catalog)
    }

    @Test("A library row with a catalog identifier remains subscription-backed")
    func resolvesCatalogBackedLibraryItem() {
        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.library-song",
            explicitCatalogIDs: ["123456789"],
            genericPlayParameterIDs: ["i.library-song"],
            confirmedLibraryIDs: ["i.library-song"]
        ) == .catalogBackedUserLibrary)

        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.library-song",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: ["i.library-song", "123456789"],
            confirmedLibraryIDs: ["i.library-song"]
        ) == .catalogBackedUserLibrary)
    }

    @Test("An unverified library row fails closed")
    func resolvesUnknownLibraryItem() {
        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.unknown-song",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: [],
            confirmedLibraryIDs: []
        ) == .unverifiedUserLibrary)

        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.unknown-song",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: ["i.unknown-song"],
            confirmedLibraryIDs: []
        ) == .unverifiedUserLibrary)

        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.unknown-song",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: ["i.unknown-song"],
            confirmedLibraryIDs: ["i.different-song"]
        ) == .unverifiedUserLibrary)

        #expect(AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(
            for: .unverifiedUserLibrary
        ))
    }

    @Test("A decoded library identifier without local provenance fails closed")
    func rejectsUnprovenLibraryItem() {
        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.imported-song",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: ["i.imported-song"],
            confirmedLibraryIDs: ["i.imported-song"]
        ) == .unverifiedUserLibrary)
    }

    @Test("Signed decimal Music.app IDs require trusted local-file provenance")
    func resolvesDecimalLocalFileItems() {
        for itemID in ["6867642289211602051", "-350135260054884126"] {
            #expect(AppleMusicPlaybackSourceResolver.resolve(
                itemID: itemID,
                explicitCatalogIDs: [],
                genericPlayParameterIDs: [itemID],
                confirmedLibraryIDs: [],
                confirmedLocalFileIDs: [itemID]
            ) == .subscriptionIndependentUserLibrary)

            #expect(AppleMusicPlaybackSourceResolver.resolve(
                itemID: itemID,
                explicitCatalogIDs: [],
                genericPlayParameterIDs: [itemID],
                confirmedLibraryIDs: [],
                confirmedLocalFileIDs: []
            ) == .catalog)
        }
    }

    @Test("A trusted persistent ID is not mistaken for a catalog ID")
    func resolvesLibraryIDWithLocalPersistentAlias() {
        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "i.imported-song",
            explicitCatalogIDs: [],
            genericPlayParameterIDs: ["i.imported-song", "6867642289211602051"],
            confirmedLibraryIDs: ["i.imported-song"],
            confirmedLocalFileIDs: ["6867642289211602051"]
        ) == .subscriptionIndependentUserLibrary)
    }

    @Test("Catalog identity takes priority over local-file provenance")
    func keepsCatalogGateForCatalogBackedLocalRows() {
        #expect(AppleMusicPlaybackSourceResolver.resolve(
            itemID: "6867642289211602051",
            explicitCatalogIDs: ["catalog-123"],
            genericPlayParameterIDs: ["6867642289211602051"],
            confirmedLibraryIDs: [],
            confirmedLocalFileIDs: ["6867642289211602051"]
        ) == .catalogBackedUserLibrary)
    }

    @Test("Persistent ID aliases cover signed MusicKit representations")
    func createsSignedPersistentIDAliases() {
        #expect(AppleMusicLocalFileIdentity.playbackIdentifiers(
            forPersistentID: 6_867_642_289_211_602_051
        ).contains("6867642289211602051"))
        #expect(AppleMusicLocalFileIdentity.playbackIdentifiers(
            forPersistentID: 0xFB24_11D6_0916_F0E2
        ).contains("-350135260054884126"))
        #expect(AppleMusicLocalFileIdentity.playbackIdentifiers(
            forPersistentID: 0xFB24_11D6_0916_F0E2
        ).contains("fb2411d60916f0e2"))
        #expect(AppleMusicLocalFileIdentity.playbackIdentifiers(
            forPersistentID: 0x123
        ).contains("0000000000000123"))
    }

    @Test("Cold lookup uses the library only for confirmed library identities")
    func choosesColdLookupEndpoint() {
        #expect(AppleMusicItemLookupPolicy.shouldUseUserLibrary(
            itemID: "i.imported-song",
            confirmedLocalFileIDs: []
        ))
        #expect(AppleMusicItemLookupPolicy.shouldUseUserLibrary(
            itemID: "-350135260054884126",
            confirmedLocalFileIDs: ["-350135260054884126"]
        ))
        #expect(!AppleMusicItemLookupPolicy.shouldUseUserLibrary(
            itemID: "123456789",
            confirmedLocalFileIDs: []
        ))
    }

    @Test("Local-file provenance requires a stable matching identifier")
    func validatesLocalFileProvenance() {
        let itemID = "6867642289211602051"
        #expect(AppleMusicLocalFileProvenancePolicy.confirmsLibrarySong(
            itemID: itemID,
            playParameterIDs: [itemID],
            persistentIDs: [itemID],
            confirmedLibraryIDs: [],
            confirmedLocalFileIDs: [itemID]
        ))

        #expect(!AppleMusicLocalFileProvenancePolicy.confirmsLibrarySong(
            itemID: itemID,
            playParameterIDs: [itemID],
            persistentIDs: ["different"],
            confirmedLibraryIDs: [],
            confirmedLocalFileIDs: [itemID]
        ))
        #expect(!AppleMusicLocalFileProvenancePolicy.confirmsLibrarySong(
            itemID: itemID,
            playParameterIDs: [itemID],
            persistentIDs: [],
            confirmedLibraryIDs: [],
            confirmedLocalFileIDs: ["different"]
        ))

        #expect(AppleMusicLocalFileProvenancePolicy.confirmsLibrarySong(
            itemID: "i.imported-song",
            playParameterIDs: ["i.imported-song"],
            persistentIDs: [itemID],
            confirmedLibraryIDs: ["i.imported-song"],
            confirmedLocalFileIDs: [itemID]
        ))

        #expect(AppleMusicLocalFileProvenancePolicy.confirmsLibrarySong(
            itemID: itemID,
            playParameterIDs: [],
            persistentIDs: [],
            confirmedLibraryIDs: [],
            confirmedLocalFileIDs: [itemID]
        ))
    }

    @Test("Only local non-DRM device music is subscription independent")
    func validatesLocalMediaEligibility() {
        #expect(AppleMusicLocalMediaEligibility.isSubscriptionIndependent(
            mediaTypeContainsMusic: true,
            hasAssetURL: true,
            isCloudItem: false,
            hasProtectedAsset: false
        ))
        #expect(!AppleMusicLocalMediaEligibility.isSubscriptionIndependent(
            mediaTypeContainsMusic: true,
            hasAssetURL: true,
            isCloudItem: true,
            hasProtectedAsset: false
        ))
        #expect(!AppleMusicLocalMediaEligibility.isSubscriptionIndependent(
            mediaTypeContainsMusic: true,
            hasAssetURL: true,
            isCloudItem: false,
            hasProtectedAsset: true
        ))
        #expect(!AppleMusicLocalMediaEligibility.isSubscriptionIndependent(
            mediaTypeContainsMusic: true,
            hasAssetURL: false,
            isCloudItem: false,
            hasProtectedAsset: false
        ))
        #expect(!AppleMusicLocalMediaEligibility.isSubscriptionIndependent(
            mediaTypeContainsMusic: false,
            hasAssetURL: true,
            isCloudItem: false,
            hasProtectedAsset: false
        ))
    }
}

@Suite("Apple Music mirror loading policy")
struct AppleMusicMirrorLoadingPolicyTests {
    @Test("Playback progress or a preflight error ends loading")
    func finishesOnPlaybackOrError() {
        #expect(AppleMusicMirrorLoadingPolicy.shouldFinishLoading(
            isPlaying: true,
            currentPlaybackTime: 0,
            playbackError: nil
        ))
        #expect(AppleMusicMirrorLoadingPolicy.shouldFinishLoading(
            isPlaying: false,
            currentPlaybackTime: 0.5,
            playbackError: nil
        ))
        #expect(AppleMusicMirrorLoadingPolicy.shouldFinishLoading(
            isPlaying: false,
            currentPlaybackTime: 0,
            playbackError: "需确认隐私声明"
        ))
    }

    @Test("An unresolved request keeps loading")
    func keepsLoadingWithoutOutcome() {
        #expect(!AppleMusicMirrorLoadingPolicy.shouldFinishLoading(
            isPlaying: false,
            currentPlaybackTime: 0,
            playbackError: nil
        ))
    }
}

@Suite("Apple Music playback-end policy")
struct AppleMusicPlaybackEndPolicyTests {
    @Test("A paused track still ends when MusicKit resets its current time")
    func recognizesPausedEndAfterTimeReset() {
        let nearEnd = AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: 240,
            playbackTime: 0,
            furthestObservedTime: 238.5
        )

        #expect(nearEnd)
        #expect(AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: true,
            wasPausedByUser: false,
            isPlaybackInterrupted: false,
            isNearEnd: nearEnd,
            stalledNearEndSampleCount: 0,
            stallSampleThreshold: 6
        ))
    }

    @Test("A frozen playing clock eventually advances")
    func recognizesFrozenPlayingEnd() {
        let nearEnd = AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: 180,
            playbackTime: 178,
            furthestObservedTime: 178
        )

        #expect(nearEnd)
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: false,
            wasPausedByUser: false,
            isPlaybackInterrupted: false,
            isNearEnd: nearEnd,
            stalledNearEndSampleCount: 5,
            stallSampleThreshold: 6
        ))
        #expect(AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: false,
            wasPausedByUser: false,
            isPlaybackInterrupted: false,
            isNearEnd: nearEnd,
            stalledNearEndSampleCount: 6,
            stallSampleThreshold: 6
        ))
    }

    @Test("User pauses and non-terminal stalls never advance")
    func rejectsManualPauseAndEarlyStall() {
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: true,
            wasPausedByUser: true,
            isPlaybackInterrupted: false,
            isNearEnd: true,
            stalledNearEndSampleCount: 0,
            stallSampleThreshold: 6
        ))
        #expect(!AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: 180,
            playbackTime: 120,
            furthestObservedTime: 120
        ))
    }

    @Test("An audio-session interruption never advances near the end")
    func rejectsInterruptedPauseOrFrozenClock() {
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: true,
            wasPausedByUser: false,
            isPlaybackInterrupted: true,
            isNearEnd: true,
            stalledNearEndSampleCount: 12,
            stallSampleThreshold: 6
        ))
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: true,
            isPaused: false,
            wasPausedByUser: false,
            isPlaybackInterrupted: true,
            isNearEnd: true,
            stalledNearEndSampleCount: 12,
            stallSampleThreshold: 6
        ))
    }
}
