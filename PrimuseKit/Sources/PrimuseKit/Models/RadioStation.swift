import Foundation

public enum PlaybackKind: String, Codable, Sendable, Hashable {
    case track
    case liveRadio
}

public struct PlaybackPresentationCapabilities: Equatable, Sendable {
    public let canSeek: Bool
    public let supportsQueue: Bool
    public let supportsLyrics: Bool
    public let supportsLibraryActions: Bool
    public let supportsMetadataActions: Bool
    public let supportsPlaybackRate: Bool
    public let supportsShuffleAndRepeat: Bool

    public static let track = PlaybackPresentationCapabilities(
        canSeek: true,
        supportsQueue: true,
        supportsLyrics: true,
        supportsLibraryActions: true,
        supportsMetadataActions: true,
        supportsPlaybackRate: true,
        supportsShuffleAndRepeat: true
    )

    public static let liveRadio = PlaybackPresentationCapabilities(
        canSeek: false,
        supportsQueue: false,
        supportsLyrics: false,
        supportsLibraryActions: false,
        supportsMetadataActions: false,
        supportsPlaybackRate: false,
        supportsShuffleAndRepeat: false
    )

    public static func capabilities(for kind: PlaybackKind) -> Self {
        switch kind {
        case .track: return .track
        case .liveRadio: return .liveRadio
        }
    }
}

public enum RadioStreamFormat: String, Codable, CaseIterable, Sendable, Hashable {
    case automatic
    case mp3
    case aac
    case flac
    case hls

    public var displayName: String {
        switch self {
        case .automatic: return PMString("radio.streamFormat.automatic")
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .flac: return "FLAC"
        case .hls: return "HLS"
        }
    }

    public var audioFormat: AudioFormat {
        switch self {
        case .automatic, .mp3, .hls: return .mp3
        case .aac: return .aac
        case .flac: return .flac
        }
    }

    public static func inferred(from url: URL, mimeType: String? = nil) -> Self {
        let mime = mimeType?.lowercased() ?? ""
        let path = url.path.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        if mime.contains("mpegurl") || mime.contains("x-mpegurl") || pathExtension == "m3u8" {
            return .hls
        }
        if mime.contains("flac") || pathExtension == "flac" || path.contains("flac") {
            return .flac
        }
        if mime.contains("aac") || mime.contains("aacp") || ["aac", "m4a"].contains(pathExtension)
            || path.contains("aac") {
            return .aac
        }
        if mime.contains("mpeg") || pathExtension == "mp3" || path.contains("mp3") {
            return .mp3
        }
        return .automatic
    }
}

public struct RadioStation: Codable, Identifiable, Hashable, Sendable {
    public static let playbackSourceID = "primuse.live-radio"

    public var id: String
    public var name: String
    public var streamURL: String
    public var logoData: Data?
    public var logoFileName: String?
    public var streamFormat: RadioStreamFormat
    public var bitRate: Int?
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastPlayedAt: Date?
    public var sortOrder: Int?
    public var isDeleted: Bool
    public var deletedAt: Date?
    /// Music-source provenance for a read-only server mirror. These fields are
    /// optional so snapshots created before server radio synchronization keep
    /// decoding through synthesized `Codable` defaults.
    public var sourceID: String?
    public var serverStationID: String?
    public var sourceName: String?
    /// Opaque source-owned playback path. When present, the app resolves a
    /// fresh authenticated URL through the source connector instead of
    /// persisting a credential-bearing URL in this value type.
    public var sourcePlaybackPath: String?
    public var homepageURL: String?
    /// 自动发现或导入清单带来的远程台标地址。和 `logoData` 的关系是「兜底」：
    /// 用户自己选过图就永远显示用户的图，这里只填补用户没选图的电台。
    /// 存的是地址而不是字节 —— 台标可能几百 KB，没必要塞进每次 CloudKit 同步。
    public var remoteLogoURL: String?
    /// 远程台标是从哪来的。决定一个新发现的候选值不值得覆盖它。
    public var remoteLogoSource: RadioLogoSource?
    /// 用户给这个电台归的文件夹。一个电台最多进一个文件夹，没有就是「未分组」。
    /// 存名字而不是 id：文件夹本身没有独立记录，见 `RadioStationOrganization`。
    public var folderName: String?
    /// 用户贴在这个电台上的标签。可选而不是空数组 —— 旧快照里没有这个键，
    /// 合成的 `Codable` 要靠可选类型才解得出来。
    public var tagNames: [String]?
    /// 这个电台来自哪份清单订阅(见 `RadioSubscription`)。下面三个字段都是可选的，
    /// 旧快照和旧版本写出的 CloudKit 记录里没有这些键，照样解得出来。
    public var subscriptionID: String?
    /// 它在清单里的身份：归一化流地址的判重键(`RadioImportParser.streamIdentityKey`)。
    /// 刷新时靠 (subscriptionID, subscriptionEntryKey) 把清单条目和电台对上。
    public var subscriptionEntryKey: String?
    /// 「用户不要清单里的这一条」。只和 `isDeleted == true` 一起出现 ——
    /// 这样的墓碑要一直留着并同步出去，清单再刷新也不会把它加回来。
    public var isSubscriptionExclusion: Bool?

    public init(
        id: String = UUID().uuidString,
        name: String,
        streamURL: String,
        logoData: Data? = nil,
        logoFileName: String? = nil,
        streamFormat: RadioStreamFormat = .automatic,
        bitRate: Int? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        sortOrder: Int? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        sourceID: String? = nil,
        serverStationID: String? = nil,
        sourceName: String? = nil,
        sourcePlaybackPath: String? = nil,
        homepageURL: String? = nil,
        remoteLogoURL: String? = nil,
        remoteLogoSource: RadioLogoSource? = nil,
        folderName: String? = nil,
        tagNames: [String]? = nil,
        subscriptionID: String? = nil,
        subscriptionEntryKey: String? = nil,
        isSubscriptionExclusion: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoData = logoData
        self.logoFileName = logoFileName
        self.streamFormat = streamFormat
        self.bitRate = bitRate
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastPlayedAt = lastPlayedAt
        self.sortOrder = sortOrder
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.sourceID = sourceID
        self.serverStationID = serverStationID
        self.sourceName = sourceName
        self.sourcePlaybackPath = sourcePlaybackPath
        self.homepageURL = homepageURL
        self.remoteLogoURL = remoteLogoURL
        self.remoteLogoSource = remoteLogoSource
        self.folderName = folderName
        self.tagNames = tagNames
        self.subscriptionID = subscriptionID
        self.subscriptionEntryKey = subscriptionEntryKey
        self.isSubscriptionExclusion = isSubscriptionExclusion
    }

    /// 归一化之后的标签。界面和筛选一律走这里，免得各处自己判空、自己去重。
    public var assignedTagNames: [String] {
        RadioStationOrganization.normalizedTagNames(tagNames) ?? []
    }

    /// 归一化之后的文件夹名，空白串一律当作没有文件夹。
    public var assignedFolderName: String? {
        RadioStationOrganization.normalizedFolderName(folderName)
    }

    public var isServerMirror: Bool {
        sourceID?.isEmpty == false && serverStationID?.isEmpty == false
    }

    /// 挂在某份清单订阅上。只看字段，不看是否已删除 —— 排除标记和刷新留下的
    /// 墓碑同样「属于」那份订阅，调用方需要时自己再判 `isDeleted`。
    public var isSubscribed: Bool {
        subscriptionID?.isEmpty == false
            && subscriptionEntryKey?.isEmpty == false
            && !isServerMirror
    }

    /// 用户删掉的订阅电台：永久墓碑，清单再刷新也不复活。
    public var isSubscriptionExclusionMarker: Bool {
        isDeleted && isSubscriptionExclusion == true
    }

    public var requiresSourceStreamResolution: Bool {
        isServerMirror && sourcePlaybackPath?.isEmpty == false
    }

    public var displayEndpoint: String {
        if let sourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceName.isEmpty {
            return sourceName
        }
        return streamURL
    }

    public var url: URL? {
        guard let url = URL(string: streamURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }

    public var playbackSong: Song {
        Song(
            id: "radio:\(id)",
            title: name,
            artistName: playbackSubtitle,
            duration: 0,
            fileFormat: streamFormat.audioFormat,
            filePath: sourcePlaybackPath ?? streamURL,
            sourceID: sourceID ?? Self.playbackSourceID,
            fileSize: 0,
            bitRate: bitRate,
            dateAdded: createdAt,
            coverArtFileName: logoFileName ?? remoteLogoURL
        )
    }

    public var playbackSubtitle: String {
        var parts: [String] = []
        if streamFormat != .automatic { parts.append(streamFormat.displayName) }
        if let bitRate, bitRate > 0 { parts.append("\(bitRate / 1_000) kbps") }
        return parts.isEmpty ? "LIVE" : parts.joined(separator: " · ")
    }
}

/// The source-backed half of a radio artwork request. Keeping this mapping in
/// PrimuseKit prevents individual screens from quietly dropping the source
/// provenance that is required to resolve server-mirrored station logos.
public struct RadioStationArtworkRemoteRequest: Hashable, Sendable {
    public let coverReference: String
    public let songID: String
    public let sourceID: String?
    public let filePath: String?
    public let fileFormat: AudioFormat

    public init(
        coverReference: String,
        songID: String,
        sourceID: String?,
        filePath: String?,
        fileFormat: AudioFormat
    ) {
        self.coverReference = coverReference
        self.songID = songID
        self.sourceID = sourceID
        self.filePath = filePath
        self.fileFormat = fileFormat
    }

    /// A versioned request discriminator prevents a late fetch for an older
    /// reference from being reused after the same station receives a new logo.
    public var cacheDiscriminator: String {
        let material = [
            songID,
            coverReference,
            sourceID ?? "",
            filePath ?? "",
            fileFormat.rawValue,
        ].joined(separator: "\u{1F}")
        return "\(songID)#artwork-\(String(Self.stableHash(material), radix: 16))"
    }

    private static func stableHash(_ value: String) -> UInt64 {
        StableFNV1a64.hash(value)
    }
}

/// FNV-1a 64 位。常量和字节顺序都是固定的，同一个字符串在任何进程、任何平台上
/// 都算出同一个值 —— 所以能拿来派生跨设备一致的 id、缓存键和配色。
/// 它是选择用的哈希，不是安全原语。
public enum StableFNV1a64 {
    public static func hash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    /// 定长 16 位小写十六进制。补零是为了让 id 长度固定，看日志时好对齐。
    public static func hexDigest(_ value: String) -> String {
        let digits = String(hash(value), radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

public enum RadioStationArtworkCandidate: Hashable, Sendable {
    case inline(Data)
    case cachedOrSource(RadioStationArtworkRemoteRequest)
}

public struct RadioStationArtworkResolutionIdentity: Hashable, Sendable {
    public let stationID: String
    public let candidates: [RadioStationArtworkCandidate]

    public init(stationID: String, candidates: [RadioStationArtworkCandidate]) {
        self.stationID = stationID
        self.candidates = candidates
    }
}

public struct RadioStationArtworkResolutionPlan: Hashable, Sendable {
    public let identity: RadioStationArtworkResolutionIdentity
    public let candidates: [RadioStationArtworkCandidate]

    public init(
        identity: RadioStationArtworkResolutionIdentity,
        candidates: [RadioStationArtworkCandidate]
    ) {
        self.identity = identity
        self.candidates = candidates
    }

    public var usesPlaceholderOnly: Bool { candidates.isEmpty }
}

/// Platform-neutral priority and fallback policy shared by every radio artwork
/// surface. Inline bytes are preferred, but a corrupt inline image must still
/// be allowed to fall through to the station's cached/source reference.
public enum RadioStationArtworkResolutionPolicy {
    /// 自动发现的远程台标在缓存里必须和用户台标分开存放。
    ///
    /// 两者过去共用电台的播放 songID 作为缓存键，而封面缓存是按键寻址到同一个
    /// 文件的 —— 远程台标只要被加载过一次，就会把用户自己选的那张图从磁盘上
    /// 顶掉。给远程候选一个独立前缀，两者从此互不覆盖。
    public static func remoteLogoCacheSongID(for stationID: String) -> String {
        "radio-remote:\(stationID)"
    }

    public static func makePlan(for station: RadioStation) -> RadioStationArtworkResolutionPlan {
        var candidates: [RadioStationArtworkCandidate] = []
        // 用户手选的图，以及音乐源自己提供的封面，都算「已经有主」的台标。
        let hasOwnedLogo = station.logoData?.isEmpty == false
            || cleaned(station.logoFileName) != nil
        if let data = station.logoData, !data.isEmpty {
            candidates.append(.inline(data))
        }
        if let reference = cleaned(station.logoFileName) {
            candidates.append(.cachedOrSource(RadioStationArtworkRemoteRequest(
                coverReference: reference,
                songID: station.playbackSong.id,
                sourceID: station.sourceID,
                filePath: station.sourcePlaybackPath ?? station.streamURL,
                fileFormat: station.streamFormat.audioFormat
            )))
        }
        // 自动发现/导入得到的远程台标只是补位：电台一旦有了自己的台标，
        // 它就彻底退场 —— 连兜底都不做。
        //
        // 不做兜底是有意的：用户的图万一加载失败(文件被缓存清理、暂时读不到)，
        // 悄悄换上一张网上抓来的图，比显示占位符更糟 —— 用户会以为自己选的图
        // 被顶掉了，而且分不清眼前这张是哪来的。
        //
        // 用户自己填的图片链接不在此列：那也是用户的选择，只是存成了地址，
        // 所以它始终参与，手选图加载不出来时由它兜底。
        //
        // 这里刻意不带 `sourceID` 和 `filePath`：这个地址属于公网，不属于任何
        // 音乐源，带上 sourceID 只会让加载层先去问一个不存在的连接器。
        if !hasOwnedLogo || station.remoteLogoSource?.isUserProvided == true,
           let remote = cleaned(station.remoteLogoURL),
           let normalized = RadioLogoURLPolicy.normalized(remote) {
            candidates.append(.cachedOrSource(RadioStationArtworkRemoteRequest(
                coverReference: normalized,
                songID: remoteLogoCacheSongID(for: station.id),
                sourceID: nil,
                filePath: nil,
                fileFormat: station.streamFormat.audioFormat
            )))
        }
        return RadioStationArtworkResolutionPlan(
            identity: RadioStationArtworkResolutionIdentity(
                stationID: station.id,
                candidates: candidates
            ),
            candidates: candidates
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct RadioStationArtworkResolution<Value> {
    public let candidate: RadioStationArtworkCandidate
    public let value: Value

    public init(candidate: RadioStationArtworkCandidate, value: Value) {
        self.candidate = candidate
        self.value = value
    }
}

extension RadioStationArtworkResolution: Sendable where Value: Sendable {}

public enum RadioStationArtworkResolver {
    public static func resolve<Value>(
        plan: RadioStationArtworkResolutionPlan,
        isolation: isolated (any Actor)? = #isolation,
        using load: (RadioStationArtworkCandidate) async -> Value?
    ) async -> RadioStationArtworkResolution<Value>? {
        for candidate in plan.candidates {
            if Task.isCancelled { return nil }
            if let value = await load(candidate) {
                if Task.isCancelled { return nil }
                return RadioStationArtworkResolution(candidate: candidate, value: value)
            }
        }
        return nil
    }
}

public enum RadioStationArtworkResultPolicy {
    public static func shouldApply(
        completedIdentity: RadioStationArtworkResolutionIdentity,
        displayedIdentity: RadioStationArtworkResolutionIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && completedIdentity == displayedIdentity
    }
}

public enum RadioStationArtworkCacheRevisionPolicy {
    public static func shouldReloadAfterInvalidation(
        invalidatesAll: Bool,
        invalidatedTokens: [String],
        request: RadioStationArtworkRemoteRequest?
    ) -> Bool {
        if invalidatesAll { return request != nil }
        guard let request else { return false }
        let localTokens = Set([request.songID, request.coverReference])
        return invalidatedTokens.contains { localTokens.contains($0) }
    }

    public static func shouldReloadAfterCaching(
        cachedSongID: String?,
        request: RadioStationArtworkRemoteRequest?,
        hasResolvedImage: Bool
    ) -> Bool {
        guard let request else { return false }
        return ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: cachedSongID,
            displayedSongID: request.songID,
            hasResolvedImage: hasResolvedImage
        )
    }
}

public struct RadioStationArtworkGridLayout: Equatable, Sendable {
    public struct Measurement: Equatable, Sendable {
        public let columnCount: Int
        public let itemWidth: Double

        public init(columnCount: Int, itemWidth: Double) {
            self.columnCount = columnCount
            self.itemWidth = itemWidth
        }
    }

    public let minimumItemWidth: Double
    public let maximumItemWidth: Double
    public let spacing: Double
    public let horizontalPadding: Double

    public init(
        minimumItemWidth: Double = 150,
        maximumItemWidth: Double = 220,
        spacing: Double = 14,
        horizontalPadding: Double = 20
    ) {
        self.minimumItemWidth = max(minimumItemWidth, 1)
        self.maximumItemWidth = max(maximumItemWidth, self.minimumItemWidth)
        self.spacing = max(spacing, 0)
        self.horizontalPadding = max(horizontalPadding, 0)
    }

    public func measure(containerWidth: Double) -> Measurement {
        let availableWidth = max(containerWidth - (horizontalPadding * 2), minimumItemWidth)
        let fittedColumns = Int((availableWidth + spacing) / (minimumItemWidth + spacing))
        let columnCount = max(fittedColumns, 1)
        let distributedWidth = (
            availableWidth - (Double(columnCount - 1) * spacing)
        ) / Double(columnCount)
        return Measurement(
            columnCount: columnCount,
            itemWidth: min(max(distributedWidth, minimumItemWidth), maximumItemWidth)
        )
    }
}

/// 电台的显示顺序与手动排序的序号。
///
/// 序号是带间隔的：相邻两台之间留 `rankStep` 个空位。挪一个台只在它两侧邻居的
/// 序号之间取一个值，别的台原样不动 —— 连续编号的话挪一次就要给几乎全部台改号，
/// 每一台都跟着逐条上传 CloudKit（音乐源镜像的台动辄几千个）。
public enum RadioStationOrdering {
    /// 相邻两台序号之间的间隔。新台接在末尾、整份归一化都按它排。
    public static let rankStep = 1_024

    public static func sorted(_ stations: [RadioStation]) -> [RadioStation] {
        stations.sorted { lhs, rhs in
            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if lhs.lastPlayedAt != rhs.lastPlayedAt {
                    return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
                }
            default:
                break
            }

            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// 紧接在 `rank` 后面一个间隔的序号。到了整数上限就停在上限，不溢出。
    public static func rank(after rank: Int) -> Int {
        let (next, overflow) = rank.addingReportingOverflow(rankStep)
        return overflow ? rank : next
    }

    /// 新台（手动添加、清单订阅、音乐源镜像）接在末尾要用的序号。
    ///
    /// 只有活着的台**全都**带序号时才给：还有没序号的台，它们按最近播放排在
    /// 有序号的台后面，给新台一个序号反而会把它插到这些台前面去；这时新台也不带序号，
    /// 跟它们一起排。最大值连墓碑一起算，复活的墓碑不会和新台撞号。
    public static func appendedRank(after stations: [RadioStation]) -> Int? {
        var hasLiveRank = false
        for station in stations where !station.isDeleted {
            guard station.sortOrder != nil else { return nil }
            hasLiveRank = true
        }
        guard hasLiveRank, let maximum = stations.compactMap(\.sortOrder).max() else { return nil }
        return rank(after: maximum)
    }

    /// 整份按给定顺序重新编号，第 i 个是 `i * rankStep`。重复的 id 只认第一次出现。
    /// 用户明确的整体重排（按名称排序）和一次性归一化用它。
    public static func denseRanks(for orderedIDs: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(orderedIDs.count)
        var next = 0
        for id in orderedIDs where result[id] == nil {
            result[id] = next * rankStep
            next += 1
        }
        return result
    }

    /// 一组被挪动的台落在哪：紧挨在某一台之前，或紧挨在某一台之后。
    public enum Anchor: Equatable, Sendable {
        case before(String)
        case after(String)
    }

    /// 只给被挪动的台算新序号，其余的台一个不动。
    ///
    /// `ordered` 是现在的完整顺序（`sorted` 排好的活电台），`movingIDs` 按挪完之后的
    /// 先后给出；它们在落点两侧邻居的序号之间等距取整数，落在最前或最后时按
    /// `rankStep` 往外排。返回值只含序号真的变了的台。
    ///
    /// 返回 nil 表示稀疏写不了，调用方要按挪完的整份顺序归一化（`denseRanks`）：
    /// - 还有台没序号 —— 它们按最近播放排，位置会自己变，落点的序号算不出来；
    /// - 落点两侧邻居之间的整数空位不够放下这几台（含两台同号）；
    /// - 给的 id 或落点在 `ordered` 里找不到，或者全部台都在挪、没有邻居可参照。
    public static func sparseRanks(
        moving movingIDs: [String],
        anchor: Anchor,
        in ordered: [RadioStation]
    ) -> [String: Int]? {
        var current: [String: Int] = [:]
        current.reserveCapacity(ordered.count)
        for station in ordered {
            guard let rank = station.sortOrder else { return nil }
            if current[station.id] == nil { current[station.id] = rank }
        }
        var movingSet = Set<String>()
        let moving = movingIDs.filter { movingSet.insert($0).inserted }
        guard !moving.isEmpty, moving.allSatisfy({ current[$0] != nil }) else { return nil }

        let remaining = ordered.filter { !movingSet.contains($0.id) }
        let insertion: Int
        switch anchor {
        case .before(let id):
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { return nil }
            insertion = index
        case .after(let id):
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { return nil }
            insertion = index + 1
        }
        let lower = insertion > 0 ? remaining[insertion - 1].sortOrder : nil
        let upper = insertion < remaining.count ? remaining[insertion].sortOrder : nil
        guard let ranks = interpolatedRanks(count: moving.count, between: lower, and: upper) else { return nil }

        var result: [String: Int] = [:]
        for (id, rank) in zip(moving, ranks) where current[id] != rank {
            result[id] = rank
        }
        return result
    }

    /// 置顶：`ids` 按给定先后排到最前，其余的台序号不动。
    ///
    /// 新序号取剩下的台里最小序号再往前数；剩下的台都没序号时从 0 起 ——
    /// 有序号的台本来就排在没序号的前面。已经按这个先后排在最前、并且都有序号时
    /// 什么都不写。返回值只含序号真的变了的台。
    public static func ranksMovingToTop(_ ids: [String], in ordered: [RadioStation]) -> [String: Int] {
        let current = Dictionary(
            ordered.map { ($0.id, $0.sortOrder) },
            uniquingKeysWith: { first, _ in first }
        )
        var movingSet = Set<String>()
        let moving = ids.filter { current[$0] != nil && movingSet.insert($0).inserted }
        guard !moving.isEmpty else { return [:] }
        if ordered.prefix(moving.count).map(\.id) == moving,
           moving.allSatisfy({ current[$0].flatMap { $0 } != nil }) {
            return [:]
        }

        let remaining = ordered.filter { !movingSet.contains($0.id) }
        let assigned: [String: Int]
        if let floor = remaining.compactMap(\.sortOrder).min() {
            if let ranks = interpolatedRanks(count: moving.count, between: nil, and: floor) {
                assigned = Dictionary(uniqueKeysWithValues: zip(moving, ranks))
            } else {
                // 序号已经逼近整数下限（只可能是坏数据）：整份按置顶后的顺序重新编号。
                assigned = denseRanks(for: moving + remaining.map(\.id))
            }
        } else {
            assigned = denseRanks(for: moving)
        }
        return assigned.filter { current[$0.key].flatMap { $0 } != $0.value }
    }

    /// `count` 个严格递增的整数：两侧都有邻居时落在 (lower, upper) 开区间里等距取整，
    /// 只有一侧时按 `rankStep` 往外排。空位不够或会溢出时返回 nil。
    static func interpolatedRanks(count: Int, between lower: Int?, and upper: Int?) -> [Int]? {
        guard count > 0 else { return [] }
        switch (lower, upper) {
        case let (lower?, upper?):
            let (span, overflow) = upper.subtractingReportingOverflow(lower)
            guard !overflow, span > count else { return nil }
            let step = span / (count + 1)
            return (1...count).map { lower + step * $0 }
        case let (lower?, nil):
            var result: [Int] = []
            result.reserveCapacity(count)
            var value = lower
            for _ in 0..<count {
                let (next, overflow) = value.addingReportingOverflow(rankStep)
                guard !overflow else { return nil }
                value = next
                result.append(value)
            }
            return result
        case let (nil, upper?):
            var result: [Int] = []
            result.reserveCapacity(count)
            var value = upper
            for _ in 0..<count {
                let (next, overflow) = value.subtractingReportingOverflow(rankStep)
                guard !overflow else { return nil }
                value = next
                result.append(value)
            }
            return result.reversed()
        case (nil, nil):
            return nil
        }
    }
}

public enum RadioStationValidation {
    public static let maximumLogoBytes = 750 * 1_024

    public static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url.absoluteString
    }

    public static func isValid(name: String, urlString: String) -> Bool {
        !normalizedName(name).isEmpty && normalizedURLString(urlString) != nil
    }

    /// Server-backed stations may intentionally omit a direct URL because an
    /// authenticated, route-aware URL is minted only when playback starts.
    public static func hasValidPlaybackReference(_ station: RadioStation) -> Bool {
        guard !normalizedName(station.name).isEmpty else { return false }
        if station.requiresSourceStreamResolution {
            return true
        }
        return normalizedURLString(station.streamURL) != nil
    }

    public static func hasConsistentServerIdentity(_ station: RadioStation) -> Bool {
        guard station.isServerMirror else { return true }
        guard let sourceID = station.sourceID,
              let serverStationID = station.serverStationID else { return false }
        return station.id == ServerRadioStationIdentity.stationID(
            sourceID: sourceID,
            serverStationID: serverStationID
        )
    }
}
