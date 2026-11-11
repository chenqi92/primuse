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
public struct MotionCoverIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var songs: [String: MotionCoverAsset]
    public var albums: [String: MotionCoverAsset]

    public init(
        songs: [String: MotionCoverAsset] = [:],
        albums: [String: MotionCoverAsset] = [:]
    ) {
        version = Self.currentVersion
        self.songs = songs
        self.albums = albums
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

    public mutating func set(_ asset: MotionCoverAsset?, for owner: MotionCoverOwner) {
        switch owner {
        case .song(let id): songs[id] = asset
        case .album(let id): albums[id] = asset
        }
    }

    /// 删掉这些歌和（已经没有歌的）专辑的设置，返回是否真删了什么。
    @discardableResult
    public mutating func remove(songIDs: Set<String>, albumIDs: Set<String>) -> Bool {
        var changed = false
        for id in songIDs where songs.removeValue(forKey: id) != nil { changed = true }
        for id in albumIDs where albums.removeValue(forKey: id) != nil { changed = true }
        return changed
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
