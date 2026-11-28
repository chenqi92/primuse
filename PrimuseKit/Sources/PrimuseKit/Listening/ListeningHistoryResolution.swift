import Foundation

public extension ListeningSongIdentity {
    /// 供目录查询粗筛候选的条件，避免把整库歌曲都物化进内存。
    struct CandidateFilterRequirements: Sendable, Equatable {
        public let sourcePaths: Set<SourcePath>
        public let subsonicCanonicalKeys: Set<SubsonicCanonicalKey>
        public let coreTitles: Set<String>

        public struct SourcePath: Sendable, Hashable {
            public let sourceID: String
            public let filePath: String

            public init(sourceID: String, filePath: String) {
                self.sourceID = sourceID
                self.filePath = filePath
            }
        }

        public struct SubsonicCanonicalKey: Sendable, Hashable {
            public let sourceID: String
            public let canonicalServerID: String
            public let fileExtension: String

            public init(sourceID: String, canonicalServerID: String, fileExtension: String) {
                self.sourceID = sourceID
                self.canonicalServerID = canonicalServerID
                self.fileExtension = fileExtension
            }
        }

        public var isEmpty: Bool {
            sourcePaths.isEmpty && subsonicCanonicalKeys.isEmpty && coreTitles.isEmpty
        }

        public func filteringDisabledSources(_ disabledSourceIDs: Set<String>) -> CandidateFilterRequirements {
            guard !disabledSourceIDs.isEmpty else { return self }
            return CandidateFilterRequirements(
                sourcePaths: sourcePaths.filter { !disabledSourceIDs.contains($0.sourceID) },
                subsonicCanonicalKeys: subsonicCanonicalKeys.filter { !disabledSourceIDs.contains($0.sourceID) },
                coreTitles: coreTitles
            )
        }

        public func matches(_ song: Song) -> Bool {
            if !sourcePaths.isEmpty,
               sourcePaths.contains(.init(sourceID: song.sourceID, filePath: song.filePath)) {
                return true
            }
            if !subsonicCanonicalKeys.isEmpty,
               let key = ListeningSongIdentity.subsonicCanonicalKey(
                   sourceID: song.sourceID, filePath: song.filePath
               ),
               subsonicCanonicalKeys.contains(key) {
                return true
            }
            if !coreTitles.isEmpty,
               coreTitles.contains(ExternalTrackMatchPolicy.normalizedCoreTitle(song.title)) {
                return true
            }
            return false
        }
    }

    static func expandingCandidateIDs(
        _ ids: [String],
        candidates: [String: [String]]
    ) -> [String] {
        guard !candidates.isEmpty, !ids.isEmpty else { return ids }
        var seen = Set(ids)
        var additions: [String] = []
        for id in ids {
            for candidate in candidates[id] ?? [] where seen.insert(candidate).inserted {
                additions.append(candidate)
            }
        }
        return additions.isEmpty ? ids : ids + additions
    }

    struct ResolvedLibraryCandidates: Sendable {
        public let candidatesByHistoryID: [String: [String]]
        public let durationsByHistoryID: [String: TimeInterval]
        public let sameSourceIDByHistoryID: [String: String]
    }

    static func candidateFilterRequirements(for events: [HomeListeningEvent]) -> CandidateFilterRequirements {
        let latest = latestEventsBySongID(events)
        var sourcePaths = Set<CandidateFilterRequirements.SourcePath>()
        var subsonicCanonicalKeys = Set<CandidateFilterRequirements.SubsonicCanonicalKey>()
        var coreTitles = Set<String>()
        for event in latest.values {
            if let sourceID = nonEmptyTrimmed(event.sourceID),
               let filePath = nonEmptyTrimmed(event.filePath) {
                sourcePaths.insert(.init(sourceID: sourceID, filePath: filePath))
                if let subsonic = subsonicCanonicalKey(sourceID: sourceID, filePath: filePath) {
                    subsonicCanonicalKeys.insert(subsonic)
                }
            }
            if let title = nonEmptyTrimmed(event.songTitle),
               nonEmptyTrimmed(event.artistName) != nil {
                let core = ExternalTrackMatchPolicy.normalizedCoreTitle(title)
                if !core.isEmpty { coreTitles.insert(core) }
            }
        }
        return CandidateFilterRequirements(
            sourcePaths: sourcePaths,
            subsonicCanonicalKeys: subsonicCanonicalKeys,
            coreTitles: coreTitles
        )
    }

    static func subsonicCanonicalKey(
        sourceID: String,
        filePath: String
    ) -> CandidateFilterRequirements.SubsonicCanonicalKey? {
        #if canImport(CryptoKit)
        guard let serverID = SubsonicSongIdentityCarryPolicy.serverSongID(fromPath: filePath) else { return nil }
        let ext = (filePath as NSString).pathExtension.lowercased()
        return CandidateFilterRequirements.SubsonicCanonicalKey(
            sourceID: sourceID,
            canonicalServerID: NavidromeCanonicalIDPolicy.canonicalID(serverID),
            fileExtension: ext
        )
        #else
        return nil
        #endif
    }

    /// 给当前曲库里按 ID 找不到的历史记录补上曲库候选：
    /// 1. 优先同源同路径（含 Navidrome 0.64 规范 ID 重编码），不依赖是否已补读标签；
    /// 2. 否则按歌名/歌手/专辑做置信匹配，并在存在精确全名匹配时收窄，避免同专辑多版本
    ///    （例如 `SUIATSU` / `SUIATSU (Deep Version)` / `SUIATSU (Boost Version)`）在缺时长时互相抵消；
    /// 3. 候选列表按同源、同路径、精确全名、ID 升序稳定排序。
    static func libraryCandidates<Songs: Sequence>(
        events: [HomeListeningEvent],
        songs: Songs
    ) -> [String: [String]] where Songs.Element == Song {
        resolveLibraryCandidates(events: events, songs: songs).candidatesByHistoryID
    }

    static func resolveLibraryCandidates<Songs: Sequence>(
        events: [HomeListeningEvent],
        songs: Songs
    ) -> ResolvedLibraryCandidates where Songs.Element == Song {
        guard !events.isEmpty else {
            return ResolvedLibraryCandidates(
                candidatesByHistoryID: [:],
                durationsByHistoryID: [:],
                sameSourceIDByHistoryID: [:]
            )
        }
        let latest = latestEventsBySongID(events)
        let requestedIDs = Set(latest.keys)

        var wantedPaths = Set<CandidateFilterRequirements.SourcePath>()
        var wantedSubsonicKeys = Set<CandidateFilterRequirements.SubsonicCanonicalKey>()
        var keys: [String: ExternalTrackMatchPolicy.Key] = [:]
        keys.reserveCapacity(latest.count)

        for (id, event) in latest {
            if let sourceID = nonEmptyTrimmed(event.sourceID),
               let filePath = nonEmptyTrimmed(event.filePath) {
                wantedPaths.insert(.init(sourceID: sourceID, filePath: filePath))
                if let subsonic = subsonicCanonicalKey(sourceID: sourceID, filePath: filePath) {
                    wantedSubsonicKeys.insert(subsonic)
                }
            }
            if let title = nonEmptyTrimmed(event.songTitle),
               let artist = nonEmptyTrimmed(event.artistName) {
                let key = cachedKey(
                    songID: id, title: title, artists: [artist], duration: event.songDuration
                )
                if key.isMatchable, !key.artistTokens.isEmpty {
                    keys[id] = key
                }
            }
        }

        guard !wantedPaths.isEmpty || !wantedSubsonicKeys.isEmpty || !keys.isEmpty else {
            return ResolvedLibraryCandidates(
                candidatesByHistoryID: [:],
                durationsByHistoryID: [:],
                sameSourceIDByHistoryID: [:]
            )
        }

        let wantedCoreTitles = Set(keys.values.map(\.coreTitle))
        var exactPresentIDs = Set<String>()
        var songsBySourcePath: [CandidateFilterRequirements.SourcePath: [Song]] = [:]
        var songsBySubsonicKey: [CandidateFilterRequirements.SubsonicCanonicalKey: [Song]] = [:]
        var buckets: [String: [(song: Song, key: ExternalTrackMatchPolicy.Key, normalizedFullTitle: String)]] = [:]

        for (position, song) in songs.enumerated() {
            if position.isMultiple(of: 256), withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
                return ResolvedLibraryCandidates(
                    candidatesByHistoryID: [:],
                    durationsByHistoryID: [:],
                    sameSourceIDByHistoryID: [:]
                )
            }
            if requestedIDs.contains(song.id) {
                exactPresentIDs.insert(song.id)
            }
            if !wantedPaths.isEmpty {
                let pathKey = CandidateFilterRequirements.SourcePath(sourceID: song.sourceID, filePath: song.filePath)
                if wantedPaths.contains(pathKey) {
                    songsBySourcePath[pathKey, default: []].append(song)
                }
            }
            if !wantedSubsonicKeys.isEmpty,
               let subsonic = subsonicCanonicalKey(sourceID: song.sourceID, filePath: song.filePath),
               wantedSubsonicKeys.contains(subsonic) {
                songsBySubsonicKey[subsonic, default: []].append(song)
            }
            if !wantedCoreTitles.isEmpty {
                let core = cachedCoreTitle(song.title)
                if wantedCoreTitles.contains(core) {
                    let key = cachedKey(
                        songID: song.id,
                        title: song.title,
                        artists: ExternalTrackMatchPolicy.artists(of: song),
                        duration: song.duration
                    )
                    let fullTitle = ExternalTrackMatchPolicy.normalize(song.title)
                    buckets[core, default: []].append((song, key, fullTitle))
                }
            }
        }

        var candidatesByHistoryID: [String: [String]] = [:]
        var durationsByHistoryID: [String: TimeInterval] = [:]
        var sameSourceIDByHistoryID: [String: String] = [:]

        for (id, event) in latest where !exactPresentIDs.contains(id) {
            let matchedSongs: [Song]
            if let pathResolved = resolveBySourcePath(
                event: event,
                key: keys[id],
                songsBySourcePath: songsBySourcePath,
                songsBySubsonicKey: songsBySubsonicKey
            ) {
                matchedSongs = pathResolved
            } else if let key = keys[id],
                      let metadataResolved = resolveByMetadata(
                          event: event,
                          key: key,
                          bucket: buckets[key.coreTitle] ?? []
                      ) {
                matchedSongs = metadataResolved
            } else {
                continue
            }

            guard !matchedSongs.isEmpty else { continue }
            candidatesByHistoryID[id] = matchedSongs.map(\.id)
            if let duration = consistentDuration(of: matchedSongs) {
                durationsByHistoryID[id] = duration
            }
            if let eventSourceID = nonEmptyTrimmed(event.sourceID),
               let sameSource = matchedSongs.first(where: { $0.sourceID == eventSourceID }) {
                sameSourceIDByHistoryID[id] = sameSource.id
            }
        }

        return ResolvedLibraryCandidates(
            candidatesByHistoryID: candidatesByHistoryID,
            durationsByHistoryID: durationsByHistoryID,
            sameSourceIDByHistoryID: sameSourceIDByHistoryID
        )
    }

    // MARK: - Resolution helpers

    private static func latestEventsBySongID(_ events: [HomeListeningEvent]) -> [String: HomeListeningEvent] {
        var latest: [String: HomeListeningEvent] = [:]
        for event in events {
            guard let known = latest[event.songID] else {
                latest[event.songID] = event
                continue
            }
            let newer = event.playedAt.timeIntervalSinceReferenceDate > known.playedAt.timeIntervalSinceReferenceDate
                ? event : known
            let older = newer.playedAt.timeIntervalSinceReferenceDate == event.playedAt.timeIntervalSinceReferenceDate
                ? known : event
            latest[event.songID] = HomeListeningEvent(
                songID: newer.songID,
                playedAt: newer.playedAt,
                listenedSeconds: newer.listenedSeconds,
                songTitle: nonEmptyTrimmed(newer.songTitle) ?? older.songTitle,
                artistName: nonEmptyTrimmed(newer.artistName) ?? older.artistName,
                albumTitle: nonEmptyTrimmed(newer.albumTitle) ?? older.albumTitle,
                songDuration: positiveDuration(newer.songDuration) ?? positiveDuration(older.songDuration),
                sourceID: nonEmptyTrimmed(newer.sourceID) ?? older.sourceID,
                filePath: nonEmptyTrimmed(newer.filePath) ?? older.filePath
            )
        }
        return latest
    }

    private static func resolveBySourcePath(
        event: HomeListeningEvent,
        key: ExternalTrackMatchPolicy.Key?,
        songsBySourcePath: [CandidateFilterRequirements.SourcePath: [Song]],
        songsBySubsonicKey: [CandidateFilterRequirements.SubsonicCanonicalKey: [Song]]
    ) -> [Song]? {
        guard let sourceID = nonEmptyTrimmed(event.sourceID),
              let filePath = nonEmptyTrimmed(event.filePath) else { return nil }
        var pathCandidates = songsBySourcePath[.init(sourceID: sourceID, filePath: filePath)] ?? []
        if pathCandidates.isEmpty,
           let subsonic = subsonicCanonicalKey(sourceID: sourceID, filePath: filePath) {
            pathCandidates = songsBySubsonicKey[subsonic] ?? []
        }
        guard !pathCandidates.isEmpty else { return nil }

        if let expectedDuration = positiveDuration(event.songDuration) {
            pathCandidates = pathCandidates.filter { song in
                guard let candidateDuration = positiveDuration(song.duration) else { return true }
                return abs(candidateDuration - expectedDuration) <= ExternalTrackMatchPolicy.rejectDurationDifference
            }
            guard !pathCandidates.isEmpty else { return nil }
        }

        let isMultiTrackContainer = pathCandidates.count > 1
            || pathCandidates.contains { $0.isCueTrack || $0.isSACDTrack }
        if !isMultiTrackContainer {
            return pathCandidates
        }

        // CUE / SACD ISO 多轨共用同一个 filePath：必须有标题或置信匹配确认，不能随便挑一首。
        var confirmed = false
        if let eventTitle = nonEmptyTrimmed(event.songTitle) {
            let normalizedFull = ExternalTrackMatchPolicy.normalize(eventTitle)
            if !normalizedFull.isEmpty {
                let exact = pathCandidates.filter {
                    ExternalTrackMatchPolicy.normalize($0.title) == normalizedFull
                }
                if !exact.isEmpty {
                    pathCandidates = exact
                    confirmed = true
                }
            }
        }
        if (!confirmed || pathCandidates.count > 1), let key {
            let confident = pathCandidates.filter { song in
                let candidateKey = cachedKey(
                    songID: song.id,
                    title: song.title,
                    artists: ExternalTrackMatchPolicy.artists(of: song),
                    duration: song.duration
                )
                return ExternalTrackMatchPolicy.verdict(key, candidateKey) == .confident
            }
            if !confident.isEmpty {
                pathCandidates = confident
                confirmed = true
            }
        }
        guard confirmed else { return nil }
        if pathCandidates.count == 1 {
            return pathCandidates
        }
        let keyed = pathCandidates.map { song in
            (
                song: song,
                key: cachedKey(
                    songID: song.id,
                    title: song.title,
                    artists: ExternalTrackMatchPolicy.artists(of: song),
                    duration: song.duration
                )
            )
        }
        guard isMutuallyConsistent(keyed.map(\.key)) else { return nil }
        return pathCandidates.sorted { $0.id < $1.id }
    }

    private static func resolveByMetadata(
        event: HomeListeningEvent,
        key: ExternalTrackMatchPolicy.Key,
        bucket: [(song: Song, key: ExternalTrackMatchPolicy.Key, normalizedFullTitle: String)]
    ) -> [Song]? {
        let album = nonEmptyTrimmed(event.albumTitle)
        var matches = bucket.filter { candidate in
            guard ExternalTrackMatchPolicy.verdict(key, candidate.key) == .confident else { return false }
            guard let album else { return true }
            return albumsMatch(expected: album, candidate: candidate.song.albumTitle)
        }
        guard !matches.isEmpty else { return nil }

        // 同专辑可能并存多个未收录为版本标记的变体（如 `SUIATSU`、`SUIATSU (Deep Version)`、
        // `SUIATSU (Boost Version)`）。存在完整歌名精确命中时先收窄到精确版本，既避免缺时长时
        // 因彼此时长不同而被整组拒掉，也避免时长接近时误播成别的版本。
        let normalizedEventTitle = ExternalTrackMatchPolicy.normalize(event.songTitle ?? "")
        if !normalizedEventTitle.isEmpty {
            let exactTitle = matches.filter { $0.normalizedFullTitle == normalizedEventTitle }
            if !exactTitle.isEmpty {
                matches = exactTitle
            }
        }

        let eventSourceID = nonEmptyTrimmed(event.sourceID)
        let eventFilePath = nonEmptyTrimmed(event.filePath)

        // 仍有多个互不相容版本时，优先收窄到同源或同路径下的自洽子集。
        if !isMutuallyConsistent(matches.map(\.key)), let eventSourceID {
            let sameSource = matches.filter { $0.song.sourceID == eventSourceID }
            if !sameSource.isEmpty, isMutuallyConsistent(sameSource.map(\.key)) {
                matches = sameSource
            }
        }
        if !isMutuallyConsistent(matches.map(\.key)), let eventFilePath {
            let samePath = matches.filter { $0.song.filePath == eventFilePath }
            if !samePath.isEmpty, isMutuallyConsistent(samePath.map(\.key)) {
                matches = samePath
            }
        }

        // 历史缺时长且曲库仍有多个互不相容的版本时，不能凭同名猜一个。
        guard isMutuallyConsistent(matches.map(\.key)) else { return nil }

        return matches.sorted { lhs, rhs in
            if let eventSourceID {
                let lhsSameSource = lhs.song.sourceID == eventSourceID
                let rhsSameSource = rhs.song.sourceID == eventSourceID
                if lhsSameSource != rhsSameSource { return lhsSameSource }
            }
            if let eventFilePath {
                let lhsSamePath = lhs.song.filePath == eventFilePath
                let rhsSamePath = rhs.song.filePath == eventFilePath
                if lhsSamePath != rhsSamePath { return lhsSamePath }
            }
            if !normalizedEventTitle.isEmpty {
                let lhsExact = lhs.normalizedFullTitle == normalizedEventTitle
                let rhsExact = rhs.normalizedFullTitle == normalizedEventTitle
                if lhsExact != rhsExact { return lhsExact }
            }
            return lhs.song.id < rhs.song.id
        }.map(\.song)
    }

    private static func isMutuallyConsistent(_ keys: [ExternalTrackMatchPolicy.Key]) -> Bool {
        guard keys.count > 1 else { return !keys.isEmpty }
        for i in keys.indices {
            for j in (i + 1)..<keys.count {
                if ExternalTrackMatchPolicy.verdict(keys[i], keys[j]) != .confident {
                    return false
                }
            }
        }
        return true
    }

    private static func consistentDuration(of songs: [Song]) -> TimeInterval? {
        let durations = songs.compactMap { positiveDuration($0.duration) }
        guard let first = durations.first else { return nil }
        guard durations.allSatisfy({ abs($0 - first) <= ExternalTrackMatchPolicy.confidentDurationTolerance }) else {
            return nil
        }
        return first
    }

    private static func albumsMatch(expected: String, candidate: String?) -> Bool {
        guard let candidate = nonEmptyTrimmed(candidate) else { return false }
        if candidate.localizedCaseInsensitiveCompare(expected) == .orderedSame {
            return true
        }
        let lhs = normalizedAlbumTitle(expected)
        let rhs = normalizedAlbumTitle(candidate)
        return !lhs.isEmpty && lhs == rhs
    }

    private static func normalizedAlbumTitle(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [
            " - ep", " – ep", " — ep", " (ep)", " [ep]",
            " - single", " – single", " — single", " (single)", " [single]",
        ]
        let lowered = trimmed.lowercased()
        for suffix in suffixes where lowered.hasSuffix(suffix) {
            let prefix = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                trimmed = prefix
                break
            }
        }
        return ExternalTrackMatchPolicy.normalize(trimmed)
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positiveDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

extension HomeListeningRanking {
    static func attachingCandidates(
        _ candidates: [String: [String]],
        to ranks: [HomeListeningRank]
    ) -> [HomeListeningRank] {
        guard !candidates.isEmpty else { return ranks }
        return ranks.map { rank in
            let groups = rank.songGroups.map {
                ListeningSongIdentity.expandingCandidateIDs($0, candidates: candidates)
            }
            var resolvedRank = HomeListeningRank(
                id: rank.id, title: rank.title, subtitle: rank.subtitle,
                songIDs: Set(groups.flatMap { $0 }).sorted(), songGroups: groups,
                artworkSongID: rank.artworkSongID, folderID: rank.folderID,
                playCount: rank.playCount, listenedSeconds: rank.listenedSeconds,
                positionsGained: rank.positionsGained
            )
            resolvedRank.isNewEntry = rank.isNewEntry
            return resolvedRank
        }
    }
}
