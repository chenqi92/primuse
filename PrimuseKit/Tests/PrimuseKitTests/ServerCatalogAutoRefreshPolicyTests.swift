import Foundation
import Testing
@testable import PrimuseKit

struct SourceAutomaticRefreshPolicyTests {
    @Test func intervalDefaultsAndInvalidStoredValuesAreConservative() {
        #expect(SourceAutomaticRefreshInterval.storedValue(nil) == .sixHours)
        #expect(SourceAutomaticRefreshInterval.storedValue(0) == .sixHours)
        #expect(SourceAutomaticRefreshInterval.storedValue(-1) == .sixHours)
        #expect(SourceAutomaticRefreshInterval.storedValue(2) == .sixHours)
        #expect(SourceAutomaticRefreshInterval.allCases.map(\.rawValue) == [1, 6, 12, 24])
    }

    @Test func selectedIntervalStartsAfterCompletionEvenIfTheScanTookLonger() throws {
        let started = Date(timeIntervalSince1970: 100_000)
        let completed = started.addingTimeInterval(30 * 60 * 60)
        for interval in SourceAutomaticRefreshInterval.allCases {
            let roundTrip = try JSONDecoder().decode(SourceAutomaticRefreshInterval.self, from: JSONEncoder().encode(interval))
            #expect(roundTrip == interval)
            #expect(SourceAutomaticRefreshInterval.storedValue(interval.rawValue) == interval)
            #expect(!SourceAutomaticRefreshPolicy.shouldRefreshFiles(
                lastScannedAt: completed, lastAttemptAt: started, interval: interval,
                now: completed.addingTimeInterval(interval.timeInterval - 1)
            ))
            #expect(SourceAutomaticRefreshPolicy.shouldRefreshFiles(
                lastScannedAt: completed, lastAttemptAt: started, interval: interval,
                now: completed.addingTimeInterval(interval.timeInterval)
            ))
        }
    }

    @Test func newAndExistingFileSourcesDefaultToOff() {
        for type in MusicSourceType.allCases {
            #expect(SourceAutomaticRefreshPolicy.isEnabled(
                for: type, sourceID: "source", disabledSourceIDs: [], optedInSourceIDs: []
            ) == type.isServerLibrary)
        }
    }

    @Test func fileSourcesCanOptInWithoutEnablingOtherSources() {
        for type in MusicSourceType.allCases where !type.isServerLibrary {
            let supported = type != .appleMusic && type != .appleMusicLibrary && !type.isAwaitingPublicAPI
            #expect(SourceAutomaticRefreshPolicy.supportsAutomaticRefresh(type) == supported)
            #expect(SourceAutomaticRefreshPolicy.isEnabled(
                for: type, sourceID: "source", disabledSourceIDs: [], optedInSourceIDs: ["source"]
            ) == supported)
            #expect(!SourceAutomaticRefreshPolicy.isEnabled(
                for: type, sourceID: "other", disabledSourceIDs: [], optedInSourceIDs: ["source"]
            ))
        }
    }

    @Test func existingDisabledServerPreferencesRemainDisabled() {
        for type in MusicSourceType.allCases {
            #expect(!SourceAutomaticRefreshPolicy.isEnabled(
                for: type, sourceID: "source", disabledSourceIDs: ["source"], optedInSourceIDs: ["source"]
            ))
        }
    }

    @Test func fileRefreshRequiresAnInitialScanAndSixHoursSinceScanOrAttempt() {
        let now = Date(timeIntervalSince1970: 100_000)
        let due = now.addingTimeInterval(-6 * 60 * 60)
        #expect(!SourceAutomaticRefreshPolicy.shouldRefreshFiles(lastScannedAt: nil, lastAttemptAt: nil, now: now))
        #expect(SourceAutomaticRefreshPolicy.shouldRefreshFiles(lastScannedAt: due, lastAttemptAt: nil, now: now))
        #expect(!SourceAutomaticRefreshPolicy.shouldRefreshFiles(lastScannedAt: due.addingTimeInterval(1), lastAttemptAt: nil, now: now))
        #expect(!SourceAutomaticRefreshPolicy.shouldRefreshFiles(lastScannedAt: due, lastAttemptAt: now.addingTimeInterval(-60), now: now))
        #expect(SourceAutomaticRefreshPolicy.shouldRefreshFiles(lastScannedAt: due, lastAttemptAt: due, now: now))
    }
}

struct ServerCatalogAutoRefreshPolicyTests {
    @Test func everySubsonicFamilyMemberGetsTheStatusProbe() {
        // All four are served by the same connector, which implements
        // getScanStatus, so the capability is family-wide.
        for type in [MusicSourceType.subsonic, .navidrome, .airsonic, .gonic] {
            #expect(ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
            #expect(ServerCatalogAutoRefreshPolicy.supportsServerScanRequest(type))
        }
    }

    @Test func sourcesThatCanOnlyRelistStayBehindAnExplicitScan() {
        // A directory walk is a scan however incrementally it reconciles, and a
        // background wake must never turn into a NAS-wide traversal.
        for type in [
            MusicSourceType.webdav, .smb, .ftp, .sftp, .nfs, .s3, .upnp,
            .synology, .qnap, .ugreen, .fnos, .local, .baiduPan,
        ] {
            #expect(!ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
        }
    }

    @Test func everyCatalogueServerGetsTheStatusProbe() {
        // Media servers answer with per-library totals and newest rows; the
        // other catalogue servers with the total of a one-row page.
        for type in [
            MusicSourceType.jellyfin, .emby, .plex, .fnMusic, .daoliyu, .songloft,
            .audiobookshelf, .synologyAudioStation, .tingReader,
        ] {
            #expect(ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
        }
        for type in MusicSourceType.allCases {
            #expect(ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type) == type.isServerLibrary)
        }
    }

    @Test func onlySubsonicServersAreAskedToScan() {
        // Jellyfin and Emby can only scan every library on the server, videos
        // included; the others have no scan request at all.
        for type in MusicSourceType.allCases where !type.isSubsonicFamily {
            #expect(!ServerCatalogAutoRefreshPolicy.supportsServerScanRequest(type))
        }
    }

    @Test func onlySubsonicServersRefreshOnceForReplayGain() {
        // The Subsonic connector started keeping `replayGain`; rows already in
        // the library only receive it from one more complete walk.
        for type in MusicSourceType.allCases {
            #expect(
                ServerCatalogAutoRefreshPolicy.catalogFieldRevision(for: type)
                    == (type.isSubsonicFamily ? 1 : 0)
            )
        }
    }

    @Test func nativeCursorSourcesKeepTheirOwnPeriodicPath() {
        // Cloud drives refresh from a durable changes cursor on a 6-hour
        // cadence; they must not also be pulled into the status-probe path.
        for type in [MusicSourceType.dropbox, .googleDrive, .oneDrive] {
            #expect(SourcePeriodicSyncPolicy.supportsAutomaticRefresh(type))
            #expect(!ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
        }
    }

    @Test func theTwoAutomaticPathsNeverOverlap() {
        for type in MusicSourceType.allCases {
            #expect(!(
                ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type)
                    && SourcePeriodicSyncPolicy.supportsAutomaticRefresh(type)
            ))
        }
    }

    @Test func probeCooldownStaysConservative() {
        #expect(ServerCatalogAutoRefreshPolicy.checkCooldown == 15 * 60)
    }

    @Test func automaticTriggersSpaceThemselvesOutUnlessAsked() {
        #expect(ServerCatalogRefreshTrigger.launch.honorsCooldown)
        #expect(ServerCatalogRefreshTrigger.foreground.honorsCooldown)
        #expect(!ServerCatalogRefreshTrigger.userRequest.honorsCooldown)
        #expect(!ServerCatalogRefreshTrigger.retry.honorsCooldown)
        #expect(ServerCatalogRefreshTrigger.userRequest.isUserInitiated)
        #expect(!ServerCatalogRefreshTrigger.foreground.isUserInitiated)
    }
}

struct ServerCatalogRefreshWorkPolicyTests {
    private func eligibility(
        _ trigger: ServerCatalogRefreshTrigger,
        active: Bool = true,
        determined: Bool = true,
        reachable: Bool = true,
        unmetered: Bool = true,
        lowPower: Bool = false,
        hot: Bool = false,
        disk: Int64 = 10 * 1_024 * 1_024 * 1_024,
        playing: Bool = false,
        requiresNetwork: Bool = true
    ) -> ServerCatalogRefreshEligibility {
        ServerCatalogRefreshWorkPolicy.eligibility(
            trigger: trigger,
            applicationIsActive: active,
            hasDeterminedNetwork: determined,
            isReachable: reachable,
            isOnUnmeteredNetwork: unmetered,
            isLowPowerModeEnabled: lowPower,
            hasSeriousThermalPressure: hot,
            availableDiskBytes: disk,
            isPlaybackBusy: playing,
            requiresNetwork: requiresNetwork
        )
    }

    @Test func automaticChecksStayOutOfTheWay() {
        for trigger in [ServerCatalogRefreshTrigger.launch, .foreground, .retry] {
            #expect(eligibility(trigger) == .allowed)
            #expect(eligibility(trigger, unmetered: false) == .deferred(.meteredNetwork))
            #expect(eligibility(trigger, lowPower: true) == .deferred(.lowPower))
            #expect(eligibility(trigger, hot: true) == .deferred(.thermalPressure))
            #expect(eligibility(trigger, playing: true) == .deferred(.playbackActive))
        }
    }

    @Test func aRequestedRefreshOnlyNeedsANetworkAndRoom() {
        #expect(eligibility(.userRequest, unmetered: false, lowPower: true, hot: true, playing: true) == .allowed)
        #expect(eligibility(.userRequest, reachable: false) == .deferred(.networkUnavailable))
        #expect(eligibility(.userRequest, determined: false) == .deferred(.networkUndetermined))
        #expect(eligibility(.userRequest, disk: 1_024) == .deferred(.insufficientDiskSpace))
        #expect(eligibility(.userRequest, active: false) == .deferred(.applicationInactive))
    }

    @Test func localFoldersCanRefreshOfflineButStillRespectResourcePressure() {
        #expect(eligibility(.foreground, determined: false, reachable: false, unmetered: false, requiresNetwork: false) == .allowed)
        #expect(eligibility(.foreground, lowPower: true, requiresNetwork: false) == .deferred(.lowPower))
        #expect(eligibility(.foreground, hot: true, requiresNetwork: false) == .deferred(.thermalPressure))
        #expect(eligibility(.foreground, playing: true, requiresNetwork: false) == .deferred(.playbackActive))
        #expect(eligibility(.foreground, active: false, requiresNetwork: false) == .deferred(.applicationInactive))
    }
}

struct ServerCatalogChangeWindowPolicyTests {
    @Test func windowStartsJustBeforeTheCheckOnTheServerClock() {
        let server = Date(timeIntervalSince1970: 10_000)
        let device = Date(timeIntervalSince1970: 50_000)
        #expect(ServerCatalogChangeWindowPolicy.nextWindowStart(
            serverObservedAt: server,
            deviceCheckedAt: device
        ) == Date(timeIntervalSince1970: 9_880))
    }

    @Test func deviceClockFallbackAllowsForSkew() {
        let device = Date(timeIntervalSince1970: 50_000)
        #expect(ServerCatalogChangeWindowPolicy.nextWindowStart(
            serverObservedAt: nil,
            deviceCheckedAt: device
        ) == Date(timeIntervalSince1970: 49_100))
    }

    @Test func aCountCoveringTheWholeCatalogueIsAnIgnoredFilter() {
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(3, totalItemCount: 1_000) == 3)
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(0, totalItemCount: 1_000) == 0)
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(1_000, totalItemCount: 1_000) == nil)
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(1_200, totalItemCount: 1_000) == nil)
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(nil, totalItemCount: 1_000) == nil)
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(-1, totalItemCount: 1_000) == nil)
        // An empty catalogue has no whole to compare against.
        #expect(ServerCatalogChangeWindowPolicy.usableChangedItemCount(0, totalItemCount: 0) == 0)
    }
}

struct ServerClockPolicyTests {
    @Test func readsTheThreeHTTPDateForms() {
        let expected = Date(timeIntervalSince1970: 784_111_777)
        #expect(ServerClockPolicy.date(fromHTTPDateHeader: "Sun, 06 Nov 1994 08:49:37 GMT") == expected)
        #expect(ServerClockPolicy.date(fromHTTPDateHeader: "Sunday, 06-Nov-94 08:49:37 GMT") == expected)
        #expect(ServerClockPolicy.date(fromHTTPDateHeader: "Sun Nov  6 08:49:37 1994") == expected)
        #expect(ServerClockPolicy.date(fromHTTPDateHeader: "  Sun, 06 Nov 1994 08:49:37 GMT ") == expected)
    }

    @Test func rejectsWhatIsNotADate() {
        #expect(ServerClockPolicy.date(fromHTTPDateHeader: "") == nil)
        #expect(ServerClockPolicy.date(fromHTTPDateHeader: "yesterday") == nil)
    }
}

struct ServerCatalogRefreshSummaryTests {
    @Test func changesOutrankEverythingElse() {
        let summary = ServerCatalogRefreshSummary(
            refreshingSourceNames: ["Emby"],
            alreadyScanningCount: 1,
            upToDateCount: 2,
            failedSourceNames: ["Plex"],
            postponedCount: 1,
            stillCheckingCount: 1
        )
        #expect(summary.headline == .refreshing(["Emby"]))
    }

    @Test func upToDateIsOnlySaidWhenNothingIsOutstanding() {
        #expect(ServerCatalogRefreshSummary(upToDateCount: 2).headline == .upToDate)
        #expect(ServerCatalogRefreshSummary(upToDateCount: 2, stillCheckingCount: 1).headline == .stillChecking)
        #expect(ServerCatalogRefreshSummary(upToDateCount: 1, postponedCount: 1).headline == .postponed)
        #expect(ServerCatalogRefreshSummary(alreadyScanningCount: 1, upToDateCount: 1).headline == .alreadyScanning)
    }

    @Test func unreachableSourcesAreNamed() {
        #expect(ServerCatalogRefreshSummary(upToDateCount: 1, failedSourceNames: ["Plex"]).headline
            == .partlyUnreachable(["Plex"]))
        #expect(ServerCatalogRefreshSummary(failedSourceNames: ["Plex", "Emby"]).headline
            == .unreachable(["Plex", "Emby"]))
    }

    @Test func nothingCheckedSaysNothing() {
        #expect(ServerCatalogRefreshSummary().headline == .nothingToCheck)
    }
}
