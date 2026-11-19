import Foundation

/// 用户自己给歌曲、专辑指定的视频动态封面。
///
/// 视频只认两种画幅：系统「正在播放」给第三方的动态封面只有方形（1:1）和竖幅（3:4）两个位置，
/// App 里的封面位按方形铺满裁切。导入时不是这两种的视频会按最接近的一种居中裁好，
/// 之后 App 内播放和交给系统都不用再处理画幅。
public enum MotionCoverAspect: String, Codable, CaseIterable, Sendable {
    case square
    case tall

    /// 宽 ÷ 高。
    public var ratio: Double {
        switch self {
        case .square: 1
        case .tall: 0.75
        }
    }

    /// 与哪一种足够接近（相对误差不超过 `tolerance`）就算哪一种；都不接近返回 nil。
    public static func matching(
        width: Double,
        height: Double,
        tolerance: Double = MotionCoverImportLimits.aspectTolerance
    ) -> MotionCoverAspect? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = width / height
        return allCases.first { abs(ratio - $0.ratio) / $0.ratio <= tolerance }
    }

    /// 需要裁切时取最接近的一种：比两者几何中点还瘦的竖视频裁成 3:4，其余（横幅、偏方的）裁成方形。
    public static func nearest(width: Double, height: Double) -> MotionCoverAspect {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .square }
        let boundary = (MotionCoverAspect.square.ratio * MotionCoverAspect.tall.ratio).squareRoot()
        return width / height >= boundary ? .square : .tall
    }

    /// 从 `sourceWidth`×`sourceHeight` 居中裁成这个画幅后的输出尺寸：长边不超过
    /// `maximumLongEdge`、不放大，宽高都是 8 的倍数（竖幅是 6×8 的倍数），比例严格等于画幅。
    public func renderSize(
        sourceWidth: Double,
        sourceHeight: Double,
        maximumLongEdge: Int = MotionCoverImportLimits.maximumLongEdge
    ) -> (width: Int, height: Int) {
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0 else {
            return (0, 0)
        }
        let cropHeight = min(sourceHeight, sourceWidth / ratio)
        let longEdge = min(Double(max(16, maximumLongEdge)), cropHeight)
        switch self {
        case .square:
            let side = max(16, Int(longEdge) / 8 * 8)
            return (side, side)
        case .tall:
            let height = max(16, Int(longEdge) / 8 * 8)
            return (height * 3 / 4, height)
        }
    }
}

public enum MotionCoverOwner: Hashable, Sendable {
    case song(String)
    case album(String)
}

/// 一段已经规整好、存进 App 自己目录的视频。按内容哈希存放，同一段视频给多首歌也只存一份。
public struct MotionCoverAsset: Codable, Equatable, Sendable {
    /// 规整后 MP4 的 SHA-256（小写十六进制），也是文件名。
    public var contentID: String
    public var aspect: MotionCoverAspect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var byteCount: Int64
    public var createdAt: Date

    public init(
        contentID: String,
        aspect: MotionCoverAspect,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double,
        byteCount: Int64,
        createdAt: Date = Date()
    ) {
        self.contentID = contentID
        self.aspect = aspect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.byteCount = byteCount
        self.createdAt = createdAt
    }

    public static func isValidContentID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// 「谁用哪段视频」的索引。歌曲自己设的优先，没有时跟随所在专辑。
///
/// 另记着每个设置最后一次被用户改动的时间和移除过的设置（墓碑），iCloud 同步按它们判新旧（#428）。
/// 这两项是后加的：旧版本写的索引没有它们，按空读进来；旧版本读新索引时忽略这两项。
public struct MotionCoverIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var songs: [String: MotionCoverAsset]
    public var albums: [String: MotionCoverAsset]
    /// 键是 `MotionCoverOwner.syncKey`，值是这个设置最后一次设、换的时间。
    /// 升级前设的没有记录，按视频导入时间（`MotionCoverAsset.createdAt`）算。
    public var modifiedAt: [String: Date]
    /// 用户移除过的设置：键同上，值是移除时间。同步时用来压过别的设备上更早的设置。
    public var removedAt: [String: Date]

    public init(
        songs: [String: MotionCoverAsset] = [:],
        albums: [String: MotionCoverAsset] = [:]
    ) {
        version = Self.currentVersion
        self.songs = songs
        self.albums = albums
        modifiedAt = [:]
        removedAt = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case version, songs, albums, modifiedAt, removedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        songs = try container.decodeIfPresent([String: MotionCoverAsset].self, forKey: .songs) ?? [:]
        albums = try container.decodeIfPresent([String: MotionCoverAsset].self, forKey: .albums) ?? [:]
        modifiedAt = (try? container.decodeIfPresent([String: Date].self, forKey: .modifiedAt)) ?? [:]
        removedAt = (try? container.decodeIfPresent([String: Date].self, forKey: .removedAt)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(songs, forKey: .songs)
        try container.encode(albums, forKey: .albums)
        if !modifiedAt.isEmpty { try container.encode(modifiedAt, forKey: .modifiedAt) }
        if !removedAt.isEmpty { try container.encode(removedAt, forKey: .removedAt) }
    }

    public func asset(for owner: MotionCoverOwner) -> MotionCoverAsset? {
        switch owner {
        case .song(let id): songs[id]
        case .album(let id): albums[id]
        }
    }

    /// 实际生效的那一段：单曲自己设的 > 专辑的。
    public func effectiveAsset(songID: String?, albumID: String?) -> (asset: MotionCoverAsset, owner: MotionCoverOwner)? {
        if let songID, !songID.isEmpty, let asset = songs[songID] {
            return (asset, .song(songID))
        }
        if let albumID, !albumID.isEmpty, let asset = albums[albumID] {
            return (asset, .album(albumID))
        }
        return nil
    }

    /// 用户设、换（`asset` 非空）或移除（`asset` 为空）一个设置，记下时间。
    public mutating func set(_ asset: MotionCoverAsset?, for owner: MotionCoverOwner, at date: Date = Date()) {
        switch owner {
        case .song(let id): songs[id] = asset
        case .album(let id): albums[id] = asset
        }
        let key = owner.syncKey
        if asset != nil {
            modifiedAt[key] = date
            removedAt[key] = nil
        } else {
            modifiedAt[key] = nil
            removedAt[key] = date
        }
    }

    /// 删掉这些歌和（已经没有歌的）专辑的设置，返回是否真删了什么。
    ///
    /// 这是本机曲库里歌没了跟着清，不是用户移除：不留墓碑，别的设备上同一首歌的设置不受影响。
    @discardableResult
    public mutating func remove(songIDs: Set<String>, albumIDs: Set<String>) -> Bool {
        var changed = false
        for id in songIDs where songs.removeValue(forKey: id) != nil {
            changed = true
            forgetStamps(for: .song(id))
        }
        for id in albumIDs where albums.removeValue(forKey: id) != nil {
            changed = true
            forgetStamps(for: .album(id))
        }
        return changed
    }

    /// 用户「全部移除」：每个设置都换成墓碑，返回原来用着的视频。
    @discardableResult
    public mutating func removeAll(at date: Date = Date()) -> Set<String> {
        let previous = referencedContentIDs
        for id in Array(songs.keys) { set(nil, for: .song(id), at: date) }
        for id in Array(albums.keys) { set(nil, for: .album(id), at: date) }
        return previous
    }

    private mutating func forgetStamps(for owner: MotionCoverOwner) {
        modifiedAt[owner.syncKey] = nil
        removedAt[owner.syncKey] = nil
    }

    /// 还被谁用着的视频；不在这里的文件可以清掉。
    public var referencedContentIDs: Set<String> {
        Set(songs.values.map(\.contentID)).union(albums.values.map(\.contentID))
    }

    public var isEmpty: Bool { songs.isEmpty && albums.isEmpty }
}

/// 导入时的限制。长边 1080：App 内的视频封面播放器只接受长边不超过 1080 的视频，
/// 锁屏全屏 3:4 位在这个尺寸下也足够清晰；60 秒：系统建议 30 秒以内的循环片段，
/// 用户手里常见的动态封面在 10 到 30 秒之间，留一倍余量。
public enum MotionCoverImportLimits {
    public static let maximumDuration: Double = 60
    public static let minimumDuration: Double = 0.3
    public static let maximumInputBytes: Int64 = 1_024 * 1_024 * 1_024
    /// 动图要整份读进内存逐帧解，上限比视频小得多。
    public static let maximumAnimationBytes = 64 * 1_024 * 1_024
    public static let maximumLongEdge = 1_080
    /// 系统不保证显示高于 60 帧的动态封面。
    public static let maximumFrameRate: Double = 60
    /// 重新编码时的帧率上限：循环封面 30 帧足够顺，文件和解码都省一半。
    public static let transcodedFrameRate: Double = 30
    public static let aspectTolerance = 0.02
    /// 经 iCloud 同步的视频上限。导入只限时长和长边，原样封装的高码率视频 60 秒可能上百 MB；
    /// 超过的只留在本机，不往 iCloud 传，也不收别的设备传来的。
    public static let maximumSyncedVideoBytes: Int64 = 100 * 1_024 * 1_024
}

public enum MotionCoverVideoCodec: String, Sendable {
    case h264
    /// 只算 `hvc1` 封装的 HEVC。`hev1` 在 Apple 的播放器里不稳，按其它编码重新转。
    case hevc
    case other
}

/// 导入前读出来的视频属性。宽高是按拍摄方向转正以后的显示尺寸。
public struct MotionCoverVideoTraits: Equatable, Sendable {
    public var duration: Double
    public var displayWidth: Double
    public var displayHeight: Double
    public var nominalFrameRate: Double
    public var hasAudioTrack: Bool
    public var hasIdentityTransform: Bool
    public var codec: MotionCoverVideoCodec
    public var isHDR: Bool
    public var fileSize: Int64

    public init(
        duration: Double,
        displayWidth: Double,
        displayHeight: Double,
        nominalFrameRate: Double,
        hasAudioTrack: Bool,
        hasIdentityTransform: Bool,
        codec: MotionCoverVideoCodec,
        isHDR: Bool,
        fileSize: Int64
    ) {
        self.duration = duration
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.nominalFrameRate = nominalFrameRate
        self.hasAudioTrack = hasAudioTrack
        self.hasIdentityTransform = hasIdentityTransform
        self.codec = codec
        self.isHDR = isHDR
        self.fileSize = fileSize
    }
}

public enum MotionCoverImportRejection: String, Error, Equatable, Sendable {
    case tooLong
    case tooLarge
    case unreadable
}

public enum MotionCoverImportPlan: Equatable, Sendable {
    /// 编码、画幅、尺寸、方向都合用：只去掉音轨，原样封装进 MP4，不重新编码。
    case remux(aspect: MotionCoverAspect)
    /// 重新编码：居中裁成 `aspect`，缩到 `width`×`height`，帧率不超过 `frameRate`。
    case transcode(aspect: MotionCoverAspect, width: Int, height: Int, frameRate: Double)
    case reject(MotionCoverImportRejection)

    public static func make(for traits: MotionCoverVideoTraits) -> MotionCoverImportPlan {
        guard traits.fileSize <= MotionCoverImportLimits.maximumInputBytes else { return .reject(.tooLarge) }
        guard traits.duration.isFinite, traits.duration >= MotionCoverImportLimits.minimumDuration else {
            return .reject(.unreadable)
        }
        // 容器里记的时长常比标称多出几帧，放一点余量。
        guard traits.duration <= MotionCoverImportLimits.maximumDuration + 0.25 else { return .reject(.tooLong) }
        guard traits.displayWidth.isFinite, traits.displayHeight.isFinite,
              traits.displayWidth > 0, traits.displayHeight > 0 else { return .reject(.unreadable) }

        let matched = MotionCoverAspect.matching(width: traits.displayWidth, height: traits.displayHeight)
        let longEdge = max(traits.displayWidth, traits.displayHeight)
        let frameRate = traits.nominalFrameRate.isFinite ? traits.nominalFrameRate : 0
        // 略超 60 秒的要重新编码精确截到 60 秒：不重编码的封装只能按关键帧截，
        // App 内的播放器读到 60 秒以后的帧就会停下。
        if let matched,
           traits.duration <= MotionCoverImportLimits.maximumDuration,
           traits.codec != .other,
           !traits.isHDR,
           traits.hasIdentityTransform,
           longEdge <= Double(MotionCoverImportLimits.maximumLongEdge),
           frameRate <= MotionCoverImportLimits.maximumFrameRate {
            return .remux(aspect: matched)
        }
        let aspect = matched ?? MotionCoverAspect.nearest(width: traits.displayWidth, height: traits.displayHeight)
        let size = aspect.renderSize(sourceWidth: traits.displayWidth, sourceHeight: traits.displayHeight)
        let targetFrameRate = frameRate > 0
            ? min(frameRate, MotionCoverImportLimits.transcodedFrameRate)
            : MotionCoverImportLimits.transcodedFrameRate
        return .transcode(aspect: aspect, width: size.width, height: size.height, frameRate: targetFrameRate)
    }

    /// GIF 等动图：逐帧重新编码成视频，按最接近的画幅居中裁。帧率字段只作标称，实际按每帧原有时长写。
    public static func forAnimation(
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double,
        frameCount: Int
    ) -> MotionCoverImportPlan {
        guard frameCount > 1, pixelWidth > 0, pixelHeight > 0,
              duration.isFinite, duration > 0 else { return .reject(.unreadable) }
        guard duration <= MotionCoverImportLimits.maximumDuration + 0.25 else { return .reject(.tooLong) }
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        let aspect = MotionCoverAspect.matching(width: width, height: height)
            ?? MotionCoverAspect.nearest(width: width, height: height)
        let size = aspect.renderSize(sourceWidth: width, sourceHeight: height)
        return .transcode(
            aspect: aspect,
            width: size.width,
            height: size.height,
            frameRate: MotionCoverImportLimits.transcodedFrameRate
        )
    }
}

// MARK: - iCloud 同步（#428）
// 用户自己设的视频动态封面经 iCloud 同步（#428）。
//
// 记录借用已经部署到生产环境的 `Playlist` 类型，不新增记录类型和字段：
// - 设置记录（谁 → 哪段视频）：ID 是 `bindingPrefix` 加归属，`songIdentities`（Bytes）里放
//   `MotionCoverSyncEntry` 的 JSON。移除也是存一条不带视频的记录（墓碑），按修改时间新的为准。
// - 视频记录：ID 是 `videoPrefix` 加内容哈希，视频放 `songIdentitiesAsset`（Asset），
//   `songIdentities` 里放一小段视频说明。旧版本解歌单时先读 `songIdentities`，解不出又没有
//   歌单名就跳过，不会把附件整段读进内存。

extension MotionCoverOwner {
    /// 索引里记时间、云端记录里记归属用的键：`s:<歌曲 id>` / `a:<专辑 id>`。
    public var syncKey: String {
        switch self {
        case .song(let id): "s:" + id
        case .album(let id): "a:" + id
        }
    }

    public init?(syncKey: String) {
        guard syncKey.count > 2 else { return nil }
        let id = String(syncKey.dropFirst(2))
        if syncKey.hasPrefix("s:") {
            self = .song(id)
        } else if syncKey.hasPrefix("a:") {
            self = .album(id)
        } else {
            return nil
        }
    }

    public var id: String {
        switch self {
        case .song(let id), .album(let id): id
        }
    }
}

/// 同步开关。设备各自决定：打开意味着这台设备要上传、下载视频，占空间和流量，
/// 所以不经 iCloud 键值同步到别的设备，也不进设置备份（和 iCloud 同步页里各项的开关一样）。
public enum MotionCoverSyncPreferences {
    public static let enabledKey = "primuse.motionCover.iCloudSync"
    public static let enabledByDefault = false

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? enabledByDefault
    }
}

/// 一个设置在云端的样子。`asset` 为空表示用户移除了。
public struct MotionCoverSyncEntry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var ownerKey: String
    public var asset: MotionCoverAsset?
    public var modifiedAt: Date

    public init(owner: MotionCoverOwner, asset: MotionCoverAsset?, modifiedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        ownerKey = owner.syncKey
        self.asset = asset
        self.modifiedAt = modifiedAt
    }

    public var owner: MotionCoverOwner? { MotionCoverOwner(syncKey: ownerKey) }

    /// 收到的记录能不能用。以后的版本改了含义会升 `schemaVersion`，这一版看不懂的不动本机。
    public var isAcceptable: Bool {
        guard schemaVersion >= 1, schemaVersion <= Self.currentSchemaVersion,
              owner != nil,
              modifiedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let asset else { return true }
        return MotionCoverSyncVideoPolicy.isAcceptable(asset)
    }
}

public enum MotionCoverSyncVideoPolicy {
    /// 视频说明本身合不合理、大小在不在同步上限内。
    public static func isAcceptable(_ asset: MotionCoverAsset) -> Bool {
        MotionCoverAsset.isValidContentID(asset.contentID)
            && asset.byteCount > 0
            && asset.byteCount <= MotionCoverImportLimits.maximumSyncedVideoBytes
            && asset.duration.isFinite
            && asset.duration > 0
            && asset.duration <= MotionCoverImportLimits.maximumDuration + 0.25
            && asset.pixelWidth > 0 && asset.pixelHeight > 0
            && max(asset.pixelWidth, asset.pixelHeight) <= MotionCoverImportLimits.maximumLongEdge
    }

    /// 本机文件能不能上传：大小（实际文件大小）在同步上限内。
    public static func isUploadable(fileSize: Int64) -> Bool {
        fileSize > 0 && fileSize <= MotionCoverImportLimits.maximumSyncedVideoBytes
    }
}

public enum MotionCoverSyncMergePolicy {
    public enum Winner: Equatable, Sendable {
        case local
        case remote
        case same
    }

    /// 同一个歌曲/专辑两边不一样时按修改时间新的为准；时间正好相同、内容不同（极少见）时
    /// 按视频哈希比大小，两台设备各自判也得到同一个结果，不会来回覆盖。
    public static func winner(local: MotionCoverSyncEntry?, remote: MotionCoverSyncEntry) -> Winner {
        guard let local else { return .remote }
        let localContent = local.asset?.contentID ?? ""
        let remoteContent = remote.asset?.contentID ?? ""
        if remote.modifiedAt > local.modifiedAt { return .remote }
        if remote.modifiedAt < local.modifiedAt { return .local }
        if localContent == remoteContent { return .same }
        return remoteContent > localContent ? .remote : .local
    }
}

public enum MotionCoverRemoteApplyResult: Equatable, Sendable {
    /// 远端的更新，已经并进索引；`replacedContentID` 是本机原来用、现在被换掉的视频。
    case applied(replacedContentID: String?)
    /// 本机的更新：应当把本机这条传回去。
    case localNewer
    case unchanged
}

extension MotionCoverIndex {
    /// 这个设置在云端应有的样子：设着的带视频，移除过的是墓碑，从没设过的没有。
    public func syncEntry(for owner: MotionCoverOwner) -> MotionCoverSyncEntry? {
        let key = owner.syncKey
        if let asset = asset(for: owner) {
            return MotionCoverSyncEntry(owner: owner, asset: asset, modifiedAt: modifiedAt[key] ?? asset.createdAt)
        }
        if let removed = removedAt[key] {
            return MotionCoverSyncEntry(owner: owner, asset: nil, modifiedAt: removed)
        }
        return nil
    }

    /// 所有要同步的设置（设着的和墓碑），按键排好。
    public var syncOwners: [MotionCoverOwner] {
        var keys = Set(songs.keys.map { MotionCoverOwner.song($0).syncKey })
        keys.formUnion(albums.keys.map { MotionCoverOwner.album($0).syncKey })
        keys.formUnion(removedAt.keys)
        return keys.sorted().compactMap(MotionCoverOwner.init(syncKey:))
    }

    /// 并入别的设备传来的设置。
    public mutating func applyRemote(_ remote: MotionCoverSyncEntry) -> MotionCoverRemoteApplyResult {
        guard remote.isAcceptable, let owner = remote.owner else { return .unchanged }
        switch MotionCoverSyncMergePolicy.winner(local: syncEntry(for: owner), remote: remote) {
        case .same:
            return .unchanged
        case .local:
            return .localNewer
        case .remote:
            let previous = asset(for: owner)?.contentID
            set(remote.asset, for: owner, at: remote.modifiedAt)
            return .applied(replacedContentID: previous == remote.asset?.contentID ? nil : previous)
        }
    }
}

/// 借用 `Playlist` 记录时的 ID 规则。前缀以下划线开头，不会和歌单 ID（UUID）、
/// 封面覆盖（`__artwork_override__:`）、大封面附件（`__song_cover_asset__:`）撞上。
public enum MotionCoverCloudRecordID {
    public static let bindingPrefix = "__motion_cover__:"
    public static let videoPrefix = "__motion_cover_video__:"

    /// 歌曲/专辑 id 过长或带记录名不允许的字符时按 `CloudRecordNameEncoding` 换成哈希，
    /// 收到时用记录里的归属反算一遍核对。
    public static func binding(for owner: MotionCoverOwner) -> String {
        let kind: String
        switch owner {
        case .song: kind = "s:"
        case .album: kind = "a:"
        }
        return bindingPrefix + kind + CloudRecordNameEncoding.recordName(for: owner.id)
    }

    public static func isBinding(_ id: String) -> Bool {
        id.hasPrefix(bindingPrefix)
    }

    public static func video(contentID: String) -> String {
        videoPrefix + contentID
    }

    public static func videoContentID(_ id: String) -> String? {
        guard id.hasPrefix(videoPrefix) else { return nil }
        let contentID = String(id.dropFirst(videoPrefix.count))
        return MotionCoverAsset.isValidContentID(contentID) ? contentID : nil
    }

    public static func isMotionCover(_ id: String) -> Bool {
        id.hasPrefix(bindingPrefix) || id.hasPrefix(videoPrefix)
    }

    /// 记录里的归属和记录 ID 对得上才收。
    public static func entry(_ entry: MotionCoverSyncEntry, matchesBinding id: String) -> Bool {
        guard let owner = entry.owner else { return false }
        return binding(for: owner) == id
    }
}
