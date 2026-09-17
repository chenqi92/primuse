import Foundation

/// 用户为 Wi-Fi 与移动网络分别选择的传输音质。
///
/// `original` 是默认值，表示「原样取原文件」—— 选中它时播放链路必须与
/// 未引入本功能时**逐字节一致**，因此所有判定的第一步都是把它挡回
/// `SourceTranscodePlan.original`。
public enum StreamQualityPreference: String, Codable, Sendable, CaseIterable {
    case original
    case kbps320
    case kbps192
    case kbps128

    /// 目标码率(kbps)。`original` 没有目标 —— 它表示不转码。
    public var targetBitRateKbps: Int? {
        switch self {
        case .original:
            return nil
        case .kbps320:
            return 320
        case .kbps192:
            return 192
        case .kbps128:
            return 128
        }
    }
}

/// 一次播放要用的取流方式。`transcode` 表示让服务端转成 mp3 渐进流。
public enum SourceTranscodePlan: Sendable, Equatable {
    case original
    case transcode(bitRateKbps: Int)

    public var isTranscode: Bool {
        if case .transcode = self { return true }
        return false
    }

    public var transcodedBitRateKbps: Int? {
        if case .transcode(let bitRateKbps) = self { return bitRateKbps }
        return nil
    }
}

/// 转码产物的一份落盘记录，用于容量清理。
public struct AdaptiveTranscodeFileRecord: Sendable, Equatable {
    public let name: String
    public let byteCount: Int64
    public let lastAccessedAt: Date

    public init(name: String, byteCount: Int64, lastAccessedAt: Date) {
        self.name = name
        self.byteCount = byteCount
        self.lastAccessedAt = lastAccessedAt
    }
}

/// 「按网络选择传输音质」的全部判定。纯函数，只依赖 Foundation，
/// 因此可以在没有 Xcode 的环境里真实执行测试。
///
/// 判定故意保守：任何信息不足的情况都回落到 `.original`。#127 的诉求是
/// 「默认保持原始音质，不要被强制转码」，宁可少转一次，也不要在拿不准的
/// 时候把用户专门存的无损降级掉。
public enum AdaptiveStreamQualityPolicy {
    /// 标记「这条流是按网络策略转码出来的」。与既有的 `primuse_transcoded`
    /// 同时出现；后者还覆盖 WMA 这类「本地解不了才转码」的存量路径，
    /// 所以本功能新增的判断一律只认这个独立标记。
    public static let adaptiveStreamQueryKey = "primuse_adaptive"

    /// 服务端转码的目标容器。播放层据此选择解码器 —— 交付的字节是 mp3，
    /// 不是 `Song.fileFormat` 描述的原始格式。
    public static let transcodedFileExtension = "mp3"

    // MARK: - 计划判定

    /// 当前网络下生效的那一项设置。
    public static func activePreference(
        wifiPreference: StreamQualityPreference,
        cellularPreference: StreamQualityPreference,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> StreamQualityPreference {
        // isExpensive 覆盖蜂窝与个人热点；isConstrained 是低数据模式。
        // 两者任一成立都按「移动网络」处理。
        if isExpensive || isConstrained {
            return cellularPreference
        }
        return wifiPreference
    }

    /// 这首歌这次该怎么取流。
    ///
    /// - Parameters:
    ///   - formatIsLossless: 取自 `AudioFormat.isLossless`。
    ///   - formatRequiresCompleteLocalFile: 取自 `FileFormatRouter.requiresCompleteLocalFile`。
    ///     这些格式有自己的整曲下载路径与后台补齐策略，v1 不碰。
    ///   - isCueTrack: 整轨 + CUE 的分轨。一张 CUE 专辑的每一条分轨指向同一个
    ///     物理文件，逐条转码会把整张专辑重复下载十几遍 —— 那比不转码更费流量。
    ///   - sourceBitRateKbps: 服务端给的原始码率(kbps)，可能缺失。
    ///   - fileSize: 原文件字节数，用于在码率缺失时估算。
    ///   - duration: 时长(秒)。为 0 时没有可信的时间轴，直接放弃转码。
    public static func plan(
        wifiPreference: StreamQualityPreference,
        cellularPreference: StreamQualityPreference,
        isExpensive: Bool,
        isConstrained: Bool,
        formatIsLossless: Bool,
        formatRequiresCompleteLocalFile: Bool,
        isCueTrack: Bool = false,
        sourceBitRateKbps: Int?,
        fileSize: Int64,
        duration: Double
    ) -> SourceTranscodePlan {
        let preference = activePreference(
            wifiPreference: wifiPreference,
            cellularPreference: cellularPreference,
            isExpensive: isExpensive,
            isConstrained: isConstrained
        )
        // 第一道且最重要的一道：两项都是默认值时这里就返回，
        // 调用方之后的每个分支都走原有代码。
        guard let target = preference.targetBitRateKbps else {
            return .original
        }
        guard target > 0 else {
            return .original
        }
        // 转码流长度未知，进度与统计全靠库里的时长；没有时长就没有可信时间轴。
        guard duration.isFinite, duration > 0 else {
            return .original
        }
        // DSD / FFmpeg 路由的格式走的是「整曲下载后解码」的另一条链路，
        // 并且后台补齐会独立去拉原文件，转码收益会被抵消。
        guard !formatRequiresCompleteLocalFile else {
            return .original
        }
        // 一张 CUE 专辑的十几条分轨共用一个物理文件, 每条各转一份整专辑
        // 会把流量放大十几倍 —— 正好与这个功能的目的相反。
        guard !isCueTrack else {
            return .original
        }
        if !formatIsLossless {
            // 有损源转成更高或相等的码率不会变好，只会白白丢掉
            // Range 拖动与持久缓存。码率拿不准时同样不转。
            guard let measured = effectiveSourceBitRateKbps(
                sourceBitRateKbps: sourceBitRateKbps,
                fileSize: fileSize,
                duration: duration
            ) else {
                return .original
            }
            guard measured > target else {
                return .original
            }
        }
        return .transcode(bitRateKbps: target)
    }

    /// 原始码率(kbps)。优先用服务端给的值，缺失时用 fileSize/duration 估算；
    /// 两者都拿不到返回 nil，调用方据此保持原始音质。
    public static func effectiveSourceBitRateKbps(
        sourceBitRateKbps: Int?,
        fileSize: Int64,
        duration: Double
    ) -> Int? {
        if let sourceBitRateKbps, sourceBitRateKbps > 0 {
            return sourceBitRateKbps
        }
        guard fileSize > 0, duration.isFinite, duration > 0 else {
            return nil
        }
        let bitsPerSecond = Double(fileSize) * 8 / duration
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else {
            return nil
        }
        let kbps = Int((bitsPerSecond / 1000).rounded())
        return kbps > 0 ? kbps : nil
    }

    // MARK: - URL 标记

    /// URL 是否带着「按网络策略转码」的标记。
    public static func isAdaptiveTranscodedStreamURL(_ url: URL) -> Bool {
        queryValue(in: url, named: adaptiveStreamQueryKey) != nil
    }

    /// 从已解析好的 URL 反推这次播放的计划。
    ///
    /// 计划必须在一次播放(playID)内保持不变，而 URL 本身就是那次决策的
    /// 产物，所以它比再读一次设置与网络状态更可靠 —— 中途切网不会让
    /// 同一首歌的判定漂移。
    public static func plan(fromResolvedURL url: URL) -> SourceTranscodePlan {
        guard isAdaptiveTranscodedStreamURL(url) else {
            return .original
        }
        guard let raw = queryValue(in: url, named: "maxBitRate"),
              let bitRate = Int(raw),
              bitRate > 0 else {
            return .original
        }
        return .transcode(bitRateKbps: bitRate)
    }

    private static func queryValue(in url: URL, named name: String) -> String? {
        // 只读 queryItems，不碰 host —— corelibs 与 Darwin 的
        // URLComponents 对 IPv6 主机的处理并不一致。
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }
        for item in items where item.name == name {
            return item.value ?? ""
        }
        return nil
    }

    // MARK: - 转码产物的落盘

    /// 转码产物放在自己的目录里，绝不与原文件的持久缓存同名同路径。
    public static let transcodeCacheDirectoryName = "primuse_adaptive_transcode"

    /// 单个转码文件名。`Song.id` 实际是十六进制摘要，但仍然过一遍白名单，
    /// 并附一个稳定指纹，避免清洗后两个不同 id 撞到同一个文件。
    public static func transcodeFileName(songID: String, bitRateKbps: Int) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(min(songID.count, 64))
        for character in songID {
            guard sanitized.count < 64 else { break }
            if character.isASCII,
               character.isLetter || character.isNumber || character == "-" || character == "_" {
                sanitized.append(character)
            }
        }
        if sanitized.isEmpty {
            sanitized = "song"
        }
        let fingerprint = stableFingerprint(songID)
        return "\(sanitized)-\(fingerprint)-\(bitRateKbps).\(transcodedFileExtension)"
    }

    /// FNV-1a 64 位。必须跨进程稳定，所以不能用 Swift 的 `Hasher`
    /// (它每次启动都换种子)。
    static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// 下载这条转码流最多允许写多少字节。
    ///
    /// 转码流没有可信的 Content-Length(实测冷转码既无 Content-Length 也不支持
    /// Range)，所以不能用原文件大小当配额。这里按 CBR 估算再留足余量：
    /// 服务端可能不完全照搬请求的码率，也可能带上 ID3 尾巴。
    public static func maximumTranscodedTransferBytes(
        bitRateKbps: Int,
        duration: Double
    ) -> Int64 {
        guard bitRateKbps > 0, duration.isFinite, duration > 0 else {
            return minimumTranscodedTransferBytes
        }
        let nominalBytes = Double(bitRateKbps) * 1000 / 8 * duration
        let padded = nominalBytes * transferHeadroomFactor + Double(transferHeadroomBytes)
        guard padded.isFinite, padded > 0 else {
            return minimumTranscodedTransferBytes
        }
        let clamped = min(padded, Double(maximumTranscodedTransferCeilingBytes))
        return max(minimumTranscodedTransferBytes, Int64(clamped))
    }

    static let transferHeadroomFactor: Double = 1.5
    static let transferHeadroomBytes: Int64 = 1 * 1024 * 1024
    static let minimumTranscodedTransferBytes: Int64 = 1 * 1024 * 1024
    /// 单曲转码产物的硬上限。320 kbps 下相当于约 8 小时。
    public static let maximumTranscodedTransferCeilingBytes: Int64 = 1_200 * 1024 * 1024

    /// 整个转码目录的容量上限。它是纯粹的临时产物，不计入用户配置的
    /// 音频缓存额度，所以单独给一个保守的小额度。
    public static let transcodeCacheLimitBytes: Int64 = 512 * 1024 * 1024

    // MARK: - 坏文件防护

    /// 转码产物「存在即完整」，没有原文件缓存那套按 `fileSize` 的兜底校验。
    /// 而 Subsonic 系服务端出错时经常回 **HTTP 200 + JSON/XML 错误体**
    /// (token 失效、无权限、id 不存在)，把那种 body 装进转码路径就等于
    /// 永久缓存了一个放不出声的文件。安装前必须先过这道校验。
    public enum TranscodedPayloadVerdict: Sendable, Equatable {
        case accepted
        case rejectedContentType(String)
        case rejectedTooSmall(Int64)
        case rejectedTextualBody
    }

    /// 合法音频的下限。Subsonic 的错误 body 通常只有几百字节；
    /// 128 kbps 下 4 KiB 才 0.25 秒，真实音频不会比这更短。
    public static let minimumTranscodedPayloadBytes: Int64 = 4 * 1024

    public static func verifyTranscodedPayload(
        contentType: String?,
        byteCount: Int64,
        leadingBytes: [UInt8]
    ) -> TranscodedPayloadVerdict {
        if let contentType {
            let normalized = contentType.lowercased()
            if normalized.contains("json")
                || normalized.contains("xml")
                || normalized.contains("html")
                || normalized.hasPrefix("text/") {
                return .rejectedContentType(normalized)
            }
        }
        guard byteCount >= minimumTranscodedPayloadBytes else {
            return .rejectedTooSmall(byteCount)
        }
        // 跳过 BOM 与前导空白后的第一个字节: `{` 是 JSON，`<` 是 XML / HTML。
        var index = 0
        if leadingBytes.count >= 3,
           leadingBytes[0] == 0xEF, leadingBytes[1] == 0xBB, leadingBytes[2] == 0xBF {
            index = 3
        }
        while index < leadingBytes.count {
            let byte = leadingBytes[index]
            let isWhitespace = byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            if !isWhitespace { break }
            index += 1
        }
        if index < leadingBytes.count {
            let first = leadingBytes[index]
            if first == 0x7B || first == 0x3C {
                return .rejectedTextualBody
            }
        }
        return .accepted
    }

    public static func acceptsTranscodedPayload(
        contentType: String?,
        byteCount: Int64,
        leadingBytes: [UInt8]
    ) -> Bool {
        verifyTranscodedPayload(
            contentType: contentType,
            byteCount: byteCount,
            leadingBytes: leadingBytes
        ) == .accepted
    }

    /// 读多少前导字节就够判断了。
    public static let payloadSniffPrefixLength = 64

    /// 超额时该删哪些转码文件：受保护的(正在播/正要播的)一律保留，
    /// 其余按最近访问时间从旧到新删到额度以内。
    public static func filesToEvict(
        _ files: [AdaptiveTranscodeFileRecord],
        limitBytes: Int64 = transcodeCacheLimitBytes,
        keeping protectedNames: Set<String> = []
    ) -> [String] {
        let total = files.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
        guard total > limitBytes else {
            return []
        }
        let evictable = files
            .filter { !protectedNames.contains($0.name) }
            .sorted { lhs, rhs in
                if lhs.lastAccessedAt == rhs.lastAccessedAt {
                    return lhs.name < rhs.name
                }
                return lhs.lastAccessedAt < rhs.lastAccessedAt
            }
        var remaining = total
        var victims: [String] = []
        for file in evictable {
            guard remaining > limitBytes else { break }
            victims.append(file.name)
            remaining -= max(0, file.byteCount)
        }
        return victims
    }
}
