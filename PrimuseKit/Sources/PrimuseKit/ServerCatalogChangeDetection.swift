import Foundation

public enum ServerCatalogRefreshDecision: Sendable, Equatable {
    case deferWhileScanning
    case refresh
    case noChanges
}

public enum ServerCatalogRefreshPolicy {
    /// Decides whether a read-only server status warrants rebuilding the local
    /// catalogue. On first use, the source's persisted successful-scan time is
    /// the migration baseline, avoiding an unconditional upgrade-time scan.
    /// `itemCount` is only a stable total after Navidrome finishes scanning;
    /// while a scan is active the same field is a progress counter.
    ///
    /// Servers without a scan clock answer with what their catalogue holds
    /// instead: `serverContentRevision` changes when rows arrive or leave, and
    /// `serverChangedItemCount` counts rows saved since the previous check,
    /// which is the only one of the three that sees an edited tag.
    public static func decision(
        serverIsScanning: Bool,
        lastAppliedServerScanAt: Date?,
        lastAppliedItemCount: Int64?,
        serverLastScanAt: Date?,
        serverItemCount: Int64?,
        localLastScannedAt: Date?,
        localSongCount: Int,
        lastAppliedContentRevision: String? = nil,
        serverContentRevision: String? = nil,
        serverChangedItemCount: Int? = nil
    ) -> ServerCatalogRefreshDecision {
        guard !serverIsScanning else { return .deferWhileScanning }

        if let serverChangedItemCount, serverChangedItemCount > 0 {
            return .refresh
        }
        if let lastAppliedContentRevision, let serverContentRevision,
           lastAppliedContentRevision != serverContentRevision {
            return .refresh
        }

        let baselineScanAt = lastAppliedServerScanAt ?? localLastScannedAt
        if let lastAppliedServerScanAt {
            guard let serverLastScanAt else { return .refresh }
            if abs(serverLastScanAt.timeIntervalSince(lastAppliedServerScanAt)) > 1 {
                return .refresh
            }
        } else if let serverLastScanAt {
            guard let localLastScannedAt else { return .refresh }
            if serverLastScanAt.timeIntervalSince(localLastScannedAt) > 1 {
                return .refresh
            }
        }

        if let serverItemCount {
            return serverItemCount != (lastAppliedItemCount ?? Int64(localSongCount))
                ? .refresh
                : .noChanges
        }
        return baselineScanAt == nil ? .refresh : .noChanges
    }
}

/// Which sources can be checked for server-side changes without behaving like
/// a scan.
///
/// The bar is a read-only answer to "did anything change?" whose cost does not
/// grow with the catalogue: a scan-status call, or one small request per music
/// library. A source that can only answer by re-listing its catalogue is
/// performing a scan, however incrementally it reconciles afterwards, and must
/// stay behind an explicit user action.
public enum ServerCatalogAutoRefreshPolicy {
    /// Minimum spacing between two automatic checks of one source.
    public static let checkCooldown: TimeInterval = 15 * 60

    /// Subsonic-family servers expose `getScanStatus`: one request, a scan flag,
    /// an item count and a last-scan timestamp. Every member of the family is
    /// served by the same connector, so the capability is family-wide rather
    /// than Navidrome-only.
    ///
    /// Jellyfin, Emby and Plex answer with one total-plus-newest-item request
    /// per music library, and Jellyfin/Emby also count rows saved since the
    /// previous check. The other catalogue servers report their total on a
    /// one-row page.
    public static func supportsStatusProbe(_ type: MusicSourceType) -> Bool {
        type.isServerLibrary
    }

    /// `startScan` is a server mutation, so it stays opt-in per source. Servers
    /// that do not implement it, and non-admin accounts, answer with a
    /// capability result rather than an error, which the caller treats as
    /// "fall back to the read-only path". Jellyfin and Emby only offer a scan
    /// of every library on the server, videos included, so they are left out.
    public static func supportsServerScanRequest(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily
    }
}

/// What set off a server catalogue check.
public enum ServerCatalogRefreshTrigger: String, Sendable, Equatable, CaseIterable {
    /// A few seconds after a cold launch.
    case launch
    /// The app came back to the foreground.
    case foreground
    /// A pull to refresh or a menu command.
    case userRequest
    /// A deferred or failed check coming round again.
    case retry

    public var isUserInitiated: Bool { self == .userRequest }

    /// Automatic checks space themselves out. A retry is already paced by its
    /// own backoff, and a check the person asked for runs now.
    public var honorsCooldown: Bool {
        switch self {
        case .launch, .foreground: true
        case .userRequest, .retry: false
        }
    }
}

public enum ServerCatalogRefreshDeferralReason: String, Sendable, Equatable {
    case applicationInactive
    case networkUndetermined
    case networkUnavailable
    case meteredNetwork
    case lowPower
    case thermalPressure
    case insufficientDiskSpace
    case playbackActive
}

public enum ServerCatalogRefreshEligibility: Sendable, Equatable {
    case allowed
    case deferred(ServerCatalogRefreshDeferralReason)
}

public enum ServerCatalogRefreshWorkPolicy {
    public static let minimumFreeDiskBytes: Int64 = 512 * 1_024 * 1_024

    /// Automatic checks stay out of the way: no cellular or Low Data Mode, no
    /// low-power or hot device, nothing while music is playing or loading. A
    /// check the person asked for only needs a network and room to write the
    /// library — they chose the moment.
    public static func eligibility(
        trigger: ServerCatalogRefreshTrigger,
        applicationIsActive: Bool,
        hasDeterminedNetwork: Bool,
        isReachable: Bool,
        isOnUnmeteredNetwork: Bool,
        isLowPowerModeEnabled: Bool,
        hasSeriousThermalPressure: Bool,
        availableDiskBytes: Int64,
        isPlaybackBusy: Bool
    ) -> ServerCatalogRefreshEligibility {
        guard applicationIsActive else { return .deferred(.applicationInactive) }
        guard hasDeterminedNetwork else { return .deferred(.networkUndetermined) }
        guard isReachable else { return .deferred(.networkUnavailable) }
        guard availableDiskBytes >= minimumFreeDiskBytes else {
            return .deferred(.insufficientDiskSpace)
        }
        if trigger.isUserInitiated { return .allowed }
        guard isOnUnmeteredNetwork else { return .deferred(.meteredNetwork) }
        guard !isLowPowerModeEnabled else { return .deferred(.lowPower) }
        guard !hasSeriousThermalPressure else { return .deferred(.thermalPressure) }
        guard !isPlaybackBusy else { return .deferred(.playbackActive) }
        return .allowed
    }
}

/// The "saved since" window a content-derived check asks about.
///
/// Each committed check leaves the next one a starting point just before its
/// own moment, measured on the server's clock when the server reports one. The
/// overlap re-counts rows saved in the last moments before a check — at most
/// one extra, cheap refresh — rather than risk skipping an edit that landed
/// while the previous check was in flight.
public enum ServerCatalogChangeWindowPolicy {
    /// Overlap when the moment came from the server's own `Date` header.
    public static let serverClockOverlap: TimeInterval = 2 * 60
    /// Overlap when only this device's clock is known. It also has to absorb
    /// ordinary skew between the two clocks.
    public static let deviceClockOverlap: TimeInterval = 15 * 60

    public static func nextWindowStart(
        serverObservedAt: Date?,
        deviceCheckedAt: Date
    ) -> Date {
        if let serverObservedAt {
            return serverObservedAt.addingTimeInterval(-serverClockOverlap)
        }
        return deviceCheckedAt.addingTimeInterval(-deviceClockOverlap)
    }

    /// A "saved since" count that covers the whole catalogue is a server that
    /// ignored the filter, not proof that every row changed. Treating it as a
    /// change would refresh on every check forever, so the signal is dropped
    /// and the content revision decides alone.
    public static func usableChangedItemCount(
        _ changedItemCount: Int?,
        totalItemCount: Int?
    ) -> Int? {
        guard let changedItemCount, changedItemCount >= 0 else { return nil }
        if let totalItemCount, totalItemCount > 0, changedItemCount >= totalItemCount {
            return nil
        }
        return changedItemCount
    }
}

/// What a person who asked for a refresh is told once every check answered.
public struct ServerCatalogRefreshSummary: Sendable, Equatable {
    /// Sources whose catalogue changed and now have a refresh running.
    public var refreshingSourceNames: [String]
    /// Sources that were already scanning when the check came round.
    public var alreadyScanningCount: Int
    /// Sources that answered "nothing changed".
    public var upToDateCount: Int
    /// Sources that could not be reached or answered with an error.
    public var failedSourceNames: [String]
    /// Sources a server-side scan or this device's conditions postponed.
    public var postponedCount: Int
    /// Sources that had not answered when the wait ended. Their checks keep
    /// going and refresh on their own if something changed.
    public var stillCheckingCount: Int

    public init(
        refreshingSourceNames: [String] = [],
        alreadyScanningCount: Int = 0,
        upToDateCount: Int = 0,
        failedSourceNames: [String] = [],
        postponedCount: Int = 0,
        stillCheckingCount: Int = 0
    ) {
        self.refreshingSourceNames = refreshingSourceNames
        self.alreadyScanningCount = alreadyScanningCount
        self.upToDateCount = upToDateCount
        self.failedSourceNames = failedSourceNames
        self.postponedCount = postponedCount
        self.stillCheckingCount = stillCheckingCount
    }

    public var checkedSourceCount: Int {
        refreshingSourceNames.count + alreadyScanningCount + upToDateCount
            + failedSourceNames.count + postponedCount + stillCheckingCount
    }

    public enum Headline: Sendable, Equatable {
        /// No source can be checked this way.
        case nothingToCheck
        /// Something changed; these sources are refreshing.
        case refreshing([String])
        /// Scans that were already running will pick up the change.
        case alreadyScanning
        /// Every reachable source is current, but some could not be reached.
        case partlyUnreachable([String])
        /// Every source is current.
        case upToDate
        /// Nothing answered.
        case unreachable([String])
        /// Some checks are still running; they refresh on their own.
        case stillChecking
        /// The checks were postponed (a server is scanning, or the device
        /// cannot do the work right now).
        case postponed
    }

    /// The one line the toast shows. Changes outrank everything, because
    /// that is what the person pulled to find out; "up to date" is only said
    /// when no source is still out.
    public var headline: Headline {
        guard checkedSourceCount > 0 else { return .nothingToCheck }
        if !refreshingSourceNames.isEmpty { return .refreshing(refreshingSourceNames) }
        if alreadyScanningCount > 0 { return .alreadyScanning }
        if stillCheckingCount > 0 { return .stillChecking }
        if !failedSourceNames.isEmpty {
            return upToDateCount > 0
                ? .partlyUnreachable(failedSourceNames)
                : .unreachable(failedSourceNames)
        }
        if postponedCount > 0 { return .postponed }
        return .upToDate
    }
}

/// Reads the moment a server stamped on its response, so a "saved since"
/// window can be kept on the server's clock instead of this device's.
public enum ServerClockPolicy {
    /// RFC 9110 `Date` header: the preferred IMF-fixdate form, plus the two
    /// obsolete forms servers are still allowed to send.
    public static func date(fromHTTPDateHeader value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
