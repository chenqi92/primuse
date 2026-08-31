#if os(tvOS)
import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers

/// 从真实封面提取的稳定双色主题。只保存 sRGB 分量，避免把 UIKit/CoreGraphics
/// 对象跨并发域传递；转换成 SwiftUI Color 始终发生在主线程的 TVStore 中。
struct TVArtworkPalette: Codable, Equatable, Sendable {
    struct RGB: Codable, Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double

        @MainActor var color: Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }

        var hex: String {
            String(
                format: "%02X%02X%02X",
                Int((min(max(red, 0), 1) * 255).rounded()),
                Int((min(max(green, 0), 1) * 255).rounded()),
                Int((min(max(blue, 0), 1) * 255).rounded())
            )
        }
    }

    let primary: RGB
    let secondary: RGB
}

/// 真实封面提色器。图片缩小、像素分析和落盘都在独立 actor / utility task 中完成，
/// UI 主线程只接收最终的几个 Double 分量。
actor TVArtworkPaletteLoader {
    static let shared = TVArtworkPaletteLoader()

    private struct CacheEntry: Codable, Sendable {
        let signature: String
        let palette: TVArtworkPalette
    }

    private struct BucketKey: Hashable, Sendable {
        let hue: Int
        let saturation: Int
        let brightness: Int
    }

    private struct Bucket: Sendable {
        var weight = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var saturation = 0.0

        mutating func add(red: Double, green: Double, blue: Double,
                          saturation: Double, weight: Double) {
            self.weight += weight
            self.red += red * weight
            self.green += green * weight
            self.blue += blue * weight
            self.saturation += saturation * weight
        }

        var average: TVArtworkPalette.RGB {
            let divisor = max(weight, .leastNonzeroMagnitude)
            return .init(red: red / divisor, green: green / divisor, blue: blue / divisor)
        }

        var score: Double {
            let divisor = max(weight, .leastNonzeroMagnitude)
            return weight * (0.55 + 0.65 * saturation / divisor)
        }
    }

    private var memoryCache: [String: CacheEntry] = [:]
    private var checkedDiskKeys: Set<String> = []
    private var latestSignature: [String: String] = [:]
    private var inFlight: [String: Task<TVArtworkPalette?, Never>] = [:]

    private var cacheDir: URL {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let dir = base.appendingPathComponent("PrimuseTVArtworkPalettes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diskURL(for artworkKey: String) -> URL {
        let name = SHA256.hash(data: Data(artworkKey.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(name).json")
    }

    /// 同一封面只分析一次；封面内容变化时 signature 会改变并自动刷新缓存。
    /// 若旧请求晚于新请求结束，会因为 latestSignature 不匹配而返回 nil，不会回写旧颜色。
    func palette(for data: Data, artworkKey: String) async -> TVArtworkPalette? {
        guard !artworkKey.isEmpty, !data.isEmpty else { return nil }
        let signature = Self.signature(of: data)
        latestSignature[artworkKey] = signature

        if let cached = memoryCache[artworkKey], cached.signature == signature {
            return cached.palette
        }

        if !checkedDiskKeys.contains(artworkKey) {
            checkedDiskKeys.insert(artworkKey)
            if let storedData = try? Data(contentsOf: diskURL(for: artworkKey)),
               let stored = try? JSONDecoder().decode(CacheEntry.self, from: storedData) {
                memoryCache[artworkKey] = stored
                if stored.signature == signature { return stored.palette }
            }
        }

        let requestKey = "\(artworkKey)|\(signature)"
        let task: Task<TVArtworkPalette?, Never>
        if let running = inFlight[requestKey] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                Self.extractPalette(from: data)
            }
            inFlight[requestKey] = task
        }

        let result = await task.value
        inFlight[requestKey] = nil

        // 同一 artwork key 已经开始处理更新的封面时，丢弃这次旧结果。
        guard latestSignature[artworkKey] == signature else { return nil }
        guard let result else { return nil }

        let entry = CacheEntry(signature: signature, palette: result)
        memoryCache[artworkKey] = entry
        if let encoded = try? JSONEncoder().encode(entry) {
            try? encoded.write(to: diskURL(for: artworkKey), options: .atomic)
        }
        return result
    }

    private nonisolated static func signature(of data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 48px 缩略图足以获得稳定色场，同时把大封面解码和逐像素计算成本限制在常数级。
    private nonisolated static func extractPalette(from data: Data) -> TVArtworkPalette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var buckets: [BucketKey: Bucket] = [:]
        let centerX = Double(width - 1) / 2
        let centerY = Double(height - 1) / 2
        let maxDistance = max(1, hypot(centerX, centerY))

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = Double(pixels[offset + 3]) / 255
                guard alpha >= 0.45 else { continue }

                // CGContext 输出 premultiplied RGBA；恢复原始颜色后再聚类。
                let red = min(1, Double(pixels[offset]) / 255 / alpha)
                let green = min(1, Double(pixels[offset + 1]) / 255 / alpha)
                let blue = min(1, Double(pixels[offset + 2]) / 255 / alpha)
                let hsv = Self.rgbToHSV(red: red, green: green, blue: blue)

                let distance = hypot(Double(x) - centerX, Double(y) - centerY) / maxDistance
                let centerWeight = 1 - min(1, distance)
                var weight = alpha * (0.82 + 0.18 * centerWeight) * (0.35 + 0.65 * hsv.saturation)
                // 纯白边框和纯黑底常占很大面积，但通常不是最能代表封面的颜色。
                if hsv.saturation < 0.08 && (hsv.brightness > 0.92 || hsv.brightness < 0.07) {
                    weight *= 0.24
                }

                let key = BucketKey(
                    hue: min(23, Int(hsv.hue * 24)),
                    saturation: min(3, Int(hsv.saturation * 4)),
                    brightness: min(3, Int(hsv.brightness * 4))
                )
                var bucket = buckets[key, default: Bucket()]
                bucket.add(red: red, green: green, blue: blue,
                           saturation: hsv.saturation, weight: weight)
                buckets[key] = bucket
            }
        }

        let candidates = buckets.values.sorted { $0.score > $1.score }
        guard let first = candidates.first else { return nil }
        let firstRGB = first.average
        let secondRGB = candidates.dropFirst().max { lhs, rhs in
            Self.secondaryScore(lhs, from: firstRGB) < Self.secondaryScore(rhs, from: firstRGB)
        }?.average

        let primary = Self.normalized(firstRGB, minimumLuminance: 0.055, maximumLuminance: 0.22,
                                      minimumBrightness: 0.30, maximumBrightness: 0.68)
        var secondary = Self.normalized(secondRGB ?? firstRGB, minimumLuminance: 0.025,
                                        maximumLuminance: 0.12,
                                        minimumBrightness: 0.16, maximumBrightness: 0.48)
        if Self.distance(primary, secondary) < 0.09 {
            secondary = Self.darkerVariant(of: primary)
        }
        return TVArtworkPalette(primary: primary, secondary: secondary)
    }

    private nonisolated static func secondaryScore(_ bucket: Bucket,
                                                    from primary: TVArtworkPalette.RGB) -> Double {
        bucket.score * (0.35 + 1.65 * min(1, distance(primary, bucket.average) * 1.4))
    }

    private nonisolated static func normalized(_ rgb: TVArtworkPalette.RGB,
                                               minimumLuminance: Double,
                                               maximumLuminance: Double,
                                               minimumBrightness: Double,
                                               maximumBrightness: Double) -> TVArtworkPalette.RGB {
        var hsv = rgbToHSV(red: rgb.red, green: rgb.green, blue: rgb.blue)
        if hsv.saturation >= 0.08 {
            hsv.saturation = min(0.82, max(0.28, hsv.saturation * 1.08))
        }
        hsv.brightness = min(maximumBrightness, max(minimumBrightness, hsv.brightness))
        var output = hsvToRGB(hue: hsv.hue, saturation: hsv.saturation, brightness: hsv.brightness)

        // sRGB 相对亮度约束：避免亮黄色/白色封面让白色 tvOS 文本失去对比，
        // 也避免黑色封面退化成完全看不见的色场。
        for _ in 0..<12 where relativeLuminance(output) > maximumLuminance {
            output = scaled(output, by: 0.9)
        }
        for _ in 0..<12 where relativeLuminance(output) < minimumLuminance {
            output = scaled(output, by: 1.1)
        }
        return output
    }

    private nonisolated static func darkerVariant(of rgb: TVArtworkPalette.RGB) -> TVArtworkPalette.RGB {
        var hsv = rgbToHSV(red: rgb.red, green: rgb.green, blue: rgb.blue)
        hsv.saturation = min(0.85, hsv.saturation + (hsv.saturation < 0.08 ? 0 : 0.08))
        hsv.brightness = max(0.16, hsv.brightness * 0.55)
        return hsvToRGB(hue: hsv.hue, saturation: hsv.saturation, brightness: hsv.brightness)
    }

    private nonisolated static func distance(_ lhs: TVArtworkPalette.RGB,
                                             _ rhs: TVArtworkPalette.RGB) -> Double {
        hypot(hypot(lhs.red - rhs.red, lhs.green - rhs.green), lhs.blue - rhs.blue)
            / sqrt(3)
    }

    private nonisolated static func relativeLuminance(_ rgb: TVArtworkPalette.RGB) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private nonisolated static func scaled(_ rgb: TVArtworkPalette.RGB,
                                           by factor: Double) -> TVArtworkPalette.RGB {
        .init(red: min(1, rgb.red * factor),
              green: min(1, rgb.green * factor),
              blue: min(1, rgb.blue * factor))
    }

    private nonisolated static func rgbToHSV(red: Double, green: Double, blue: Double)
        -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = (green - blue) / delta
                if hue < 0 { hue += 6 }
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
        }
        let saturation = maximum == 0 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }

    private nonisolated static func hsvToRGB(hue: Double, saturation: Double, brightness: Double)
        -> TVArtworkPalette.RGB {
        guard saturation > 0 else {
            return .init(red: brightness, green: brightness, blue: brightness)
        }
        let position = (hue - floor(hue)) * 6
        let sector = Int(floor(position)) % 6
        let fraction = position - floor(position)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return .init(red: brightness, green: t, blue: p)
        case 1: return .init(red: q, green: brightness, blue: p)
        case 2: return .init(red: p, green: brightness, blue: t)
        case 3: return .init(red: p, green: q, blue: brightness)
        case 4: return .init(red: t, green: p, blue: brightness)
        default: return .init(red: brightness, green: p, blue: q)
        }
    }
}

/// tvOS 封面加载:同步/本机缓存优先，飞牛音乐引用通过共享服务客户端读取，
/// 专辑可回退 iTunes Search，散曲可回退安全的 HTTP(S) 引用；取不到时回到程序化封面。
actor TVArtworkLoader {
    static let shared = TVArtworkLoader()

    private struct StaticArtworkPreparation: Sendable {
        let displayData: Data
        let mayContainAnimation: Bool
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Data?, Never>]
    }

    private struct CachedAnimationDescriptor {
        let generation: String
        let descriptor: ArtworkDescriptor
    }

    private var inFlight: [String: InFlightEntry] = [:]
    private var negativeUntil: [String: Date] = [:]
    private var animationDescriptors: [String: CachedAnimationDescriptor] = [:]
    private var animationDescriptorLRU: [String] = []
    static let negativeCacheTTL: TimeInterval = 5 * 60
    private static let maximumRemoteArtworkBytes = 8 * 1024 * 1024
    private static let maximumAnimatedArtworkBytes =
        ArtworkAnimationLimits.default.maximumCompressedBytes
    private static let maximumSearchResponseBytes = 1 * 1024 * 1024
    private static let staticAnimationNegativeTTL: TimeInterval = 24 * 60 * 60
    private static let animationDiskCache: ArtworkAnimationDiskCache = {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let directory = base
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("TVAnimatedArtwork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        return ArtworkAnimationDiskCache(directory: directory)
    }()
    private static let remoteArtworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: config,
            delegate: TVInsecureTLSDelegate(),
            delegateQueue: nil
        )
    }()

    private var cacheDir: URL {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let dir = base.appendingPathComponent("PrimuseTVArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func diskURL(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(h).jpg")
    }

    /// 按 (artist, album) 取专辑封面 Data;key 用于缓存去重(一般传 albumID)。
    func cover(key: String, artist: String, album: String) async -> Data? {
        guard !Task.isCancelled,
              !key.isEmpty,
              !(artist.isEmpty && album.isEmpty) else { return nil }
        let disk = diskURL(key)
        if let data = try? Data(contentsOf: disk) {
            let displayData = await preparedStaticArtwork(data)
            guard !Task.isCancelled else { return nil }
            if let displayData {
                if displayData != data {
                    try? displayData.write(to: disk, options: .atomic)
                }
                return displayData
            }
            // Old builds could persist an HTTP error body with a .jpg suffix.
            // It is disposable cache data, so remove it and recover online.
            try? FileManager.default.removeItem(at: disk)
        }
        if isTemporarilyNegative(key) { return nil }
        let requestKey = "static-album-search:\(key)"
        let fetched = await deduplicatedFetch(key: requestKey) {
            await Self.fetchITunes(
                term: "\(artist) \(album)".trimmingCharacters(in: .whitespaces)
            )
        }
        guard !Task.isCancelled else { return nil }
        guard let fetched else {
            markTemporarilyNegative(key)
            return nil
        }
        let prepared = await preparedStaticArtwork(fetched)
        guard !Task.isCancelled else { return nil }
        guard let result = prepared else {
            markTemporarilyNegative(key)
            return nil
        }
        negativeUntil.removeValue(forKey: key)
        try? result.write(to: disk, options: .atomic)
        return result
    }

    /// 歌曲级封面：歌曲缓存优先；飞牛音乐按带 revision 的来源引用独立缓存，
    /// 其次兼容旧本地引用和飞牛音乐的鉴权读取，
    /// 最后只对 HTTP(S) 封面引用发起有限大小的请求。其它源端路径不在这里猜测，
    /// 避免把未经解析的 NAS 路径当成公网 URL 或绕过源凭据体系。
    func songCover(
        songID: String,
        coverRef: String?,
        fnMusicSourceID: String? = nil,
        fnMusicClient: FnMusicServiceClient? = nil,
        animationCacheKey: String? = nil
    ) async -> Data? {
        guard !Task.isCancelled, !songID.isEmpty else { return nil }
        let ref = coverRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fnMusicRequestKey = FnMusicAPIProtocol.coverID(from: ref).map { _ in
            "fnmusic-cover:\(fnMusicSourceID ?? songID)|\(ref)"
        }

        if let fnMusicRequestKey {
            let disk = diskURL(fnMusicRequestKey)
            if let data = try? Data(contentsOf: disk) {
                let displayData = await preparedSongArtwork(
                    data,
                    songID: songID,
                    animationCacheKey: animationCacheKey
                )
                guard !Task.isCancelled else { return nil }
                if let displayData {
                    if displayData != data {
                        try? displayData.write(to: disk, options: .atomic)
                    }
                    return displayData
                }
                try? FileManager.default.removeItem(at: disk)
            }
        } else if let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) {
            return await preparedSongArtwork(
                cached,
                songID: songID,
                animationCacheKey: animationCacheKey
            )
        }

        guard !ref.isEmpty else { return nil }

        if MetadataAssetStore.shared.isLegacyLocalRef(ref),
           let data = MetadataAssetStore.shared.readCoverData(named: ref),
           Self.isImageData(data) {
            return await preparedSongArtwork(
                data,
                songID: songID,
                animationCacheKey: animationCacheKey
            )
        }

        if let fnMusicRequestKey {
            guard let fnMusicClient else { return nil }
            if isTemporarilyNegative(fnMusicRequestKey) { return nil }
            let result = await deduplicatedFetch(
                key: "static:\(fnMusicRequestKey)"
            ) {
                guard !Task.isCancelled,
                      let data = try? await fnMusicClient.coverData(reference: ref),
                      !Task.isCancelled,
                      Self.isImageData(data) else {
                    return nil
                }
                return data
            }
            guard !Task.isCancelled else { return nil }
            guard let result else {
                markTemporarilyNegative(fnMusicRequestKey)
                return nil
            }
            negativeUntil.removeValue(forKey: fnMusicRequestKey)
            guard let displayData = await preparedSongArtwork(
                result,
                songID: songID,
                animationCacheKey: animationCacheKey
            ) else { return nil }
            try? displayData.write(to: diskURL(fnMusicRequestKey), options: .atomic)
            return displayData
        }

        guard let url = URL(string: ref),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }

        let requestKey = "song:\(songID)|\(ref)"
        if isTemporarilyNegative(requestKey) { return nil }
        let result = await deduplicatedFetch(key: "static:\(requestKey)") {
            await Self.fetchRemoteArtwork(
                from: url,
                maximumBytes: Self.maximumRemoteArtworkBytes
            )
        }
        guard !Task.isCancelled else { return nil }
        guard let result else {
            markTemporarilyNegative(requestKey)
            return nil
        }
        negativeUntil.removeValue(forKey: requestKey)
        return await preparedSongArtwork(
            result,
            songID: songID,
            animationCacheKey: animationCacheKey
        )
    }

    /// Reads the exact source used by an animated hero without consulting the
    /// single-frame song cache. Direct remote references get the animation
    /// budget; ordinary artwork requests keep their smaller static budget.
    func originalAnimationCandidate(
        songID: String,
        coverRef: String?,
        fnMusicSourceID: String? = nil,
        fnMusicClient: FnMusicServiceClient? = nil,
        requestKey: String
    ) async -> Data? {
        guard !Task.isCancelled,
              !songID.isEmpty,
              !requestKey.isEmpty else { return nil }
        let ref = coverRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ref.isEmpty else { return nil }

        if MetadataAssetStore.shared.isLegacyLocalRef(ref),
           let data = MetadataAssetStore.shared.readCoverData(named: ref),
           data.count <= Self.maximumAnimatedArtworkBytes,
           Self.isImageData(data) {
            return Task.isCancelled ? nil : data
        }

        if FnMusicAPIProtocol.coverID(from: ref) != nil {
            guard let fnMusicClient else { return nil }
            return await deduplicatedFetch(
                key: "hero-fnmusic:\(fnMusicSourceID ?? songID)|\(requestKey)"
            ) {
                guard !Task.isCancelled,
                      let data = try? await fnMusicClient.coverData(
                        reference: ref,
                        size: 2_048,
                        maximumBytes: Self.maximumAnimatedArtworkBytes
                      ),
                      !Task.isCancelled,
                      data.count <= Self.maximumAnimatedArtworkBytes,
                      Self.isImageData(data) else {
                    return nil
                }
                return data
            }
        }

        guard let url = URL(string: ref),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return await deduplicatedFetch(key: "hero-http:\(requestKey)") {
            await Self.fetchRemoteArtwork(
                from: url,
                maximumBytes: Self.maximumAnimatedArtworkBytes
            )
        }
    }

    func cachedAnimation(
        forKey key: String
    ) async -> ArtworkAnimationDiskCache.DetailedLookupResult? {
        guard !key.isEmpty else { return nil }
        return try? await Self.animationDiskCache.detailedLookup(forKey: key)
    }

    func cacheValidatedAnimation(_ data: Data, forKey key: String) async -> String? {
        guard !key.isEmpty else { return nil }
        removeAnimationDescriptor(forKey: key)
        return try? await Self.animationDiskCache.storeAsset(data, forKey: key)
    }

    func cachedAnimationDescriptor(
        forKey key: String,
        generation: String
    ) -> ArtworkDescriptor? {
        guard let cached = animationDescriptors[key],
              cached.generation == generation else { return nil }
        animationDescriptorLRU.removeAll(where: { $0 == key })
        animationDescriptorLRU.append(key)
        return cached.descriptor
    }

    func cacheAnimationDescriptor(
        _ descriptor: ArtworkDescriptor,
        forKey key: String,
        generation: String
    ) {
        guard !key.isEmpty, !generation.isEmpty else { return }
        animationDescriptors[key] = CachedAnimationDescriptor(
            generation: generation,
            descriptor: descriptor
        )
        animationDescriptorLRU.removeAll(where: { $0 == key })
        animationDescriptorLRU.append(key)
        while animationDescriptorLRU.count > 32 {
            let evictedKey = animationDescriptorLRU.removeFirst()
            animationDescriptors.removeValue(forKey: evictedKey)
        }
    }

    func recordStaticAnimationResult(
        forKey key: String,
        matchingGeneration generation: String? = nil
    ) async {
        guard !key.isEmpty else { return }
        let now = Date()
        let expiresAt = now.addingTimeInterval(Self.staticAnimationNegativeTTL)
        let stored: Bool
        if let generation {
            stored = (try? await Self.animationDiskCache.replaceAssetWithNegative(
                forKey: key,
                matchingGeneration: generation,
                expiresAt: expiresAt,
                now: now
            )) ?? false
        } else {
            stored = (try? await Self.animationDiskCache.storeNegativeIfAssetMissing(
                forKey: key,
                expiresAt: expiresAt,
                now: now
            )) ?? false
        }
        if stored,
           generation == nil || animationDescriptors[key]?.generation == generation {
            removeAnimationDescriptor(forKey: key)
        }
    }

    func removeAnimationEntry(forKey key: String) async {
        guard !key.isEmpty else { return }
        removeAnimationDescriptor(forKey: key)
        try? await Self.animationDiskCache.removeValue(forKey: key)
    }

    func preparedAlbumArtwork(
        _ data: Data,
        albumID: String,
        animationCacheKey: String?
    ) async -> Data? {
        guard let displayData = await preparedStaticArtwork(
            data,
            animationCacheKey: animationCacheKey
        ) else { return nil }
        if displayData != data {
            _ = await MetadataAssetStore.shared.storeAlbumCover(
                displayData,
                forAlbumID: albumID
            )
        }
        guard !Task.isCancelled else { return nil }
        return displayData
    }

    func preparedHeroFallback(_ data: Data) async -> Data? {
        await preparedStaticArtwork(data)
    }

    /// The ordinary artwork cache is deliberately single-frame. Static surfaces
    /// never inspect frame metadata; animation-capable containers are retained
    /// as bounded candidates for a hero surface and mirrored from frame zero.
    private func preparedStaticArtwork(
        _ data: Data,
        animationCacheKey: String? = nil
    ) async -> Data? {
        let preparationTask = Task.detached(priority: .utility) {
            Self.prepareStaticArtwork(data)
        }
        let preparation = await withTaskCancellationHandler {
            await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
        guard !Task.isCancelled, let preparation else { return nil }
        if preparation.mayContainAnimation,
           let animationCacheKey,
           !animationCacheKey.isEmpty {
            await preserveAnimationCandidate(data, forKey: animationCacheKey)
        }
        guard !Task.isCancelled else { return nil }
        return preparation.displayData
    }

    private nonisolated static func prepareStaticArtwork(
        _ data: Data
    ) -> StaticArtworkPreparation? {
        guard isImageData(data) else { return nil }
        let mayContainAnimation = isAnimationContainerCandidate(data)
        let displayData: Data
        if mayContainAnimation {
            guard let mirror = ArtworkImageCompatibility.staticFirstFrameJPEG(from: data) else {
                return nil
            }
            displayData = mirror
        } else {
            displayData = data
        }
        return StaticArtworkPreparation(
            displayData: displayData,
            mayContainAnimation: mayContainAnimation
        )
    }

    private func preparedSongArtwork(
        _ data: Data,
        songID: String,
        animationCacheKey: String?
    ) async -> Data? {
        guard let displayData = await preparedStaticArtwork(
            data,
            animationCacheKey: animationCacheKey
        ) else { return nil }
        let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID)
        if cached != displayData {
            await MetadataAssetStore.shared.cacheCover(displayData, forSongID: songID)
        }
        guard !Task.isCancelled else { return nil }
        return displayData
    }

    private func preserveAnimationCandidate(_ data: Data, forKey key: String) async {
        do {
            _ = try await Self.animationDiskCache.storeAssetIfValueMissing(
                data,
                forKey: key
            )
        } catch {
            // A disposable animation cache failure must not hide static artwork.
        }
    }

    private func removeAnimationDescriptor(forKey key: String) {
        animationDescriptors.removeValue(forKey: key)
        animationDescriptorLRU.removeAll(where: { $0 == key })
    }

    private func deduplicatedFetch(
        key: String,
        operation: @Sendable @escaping () async -> Data?
    ) async -> Data? {
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(
                    waiterID,
                    for: key,
                    operation: operation,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }
        return Task.isCancelled ? nil : result
    }

    private func registerWaiter(
        _ waiterID: UUID,
        for key: String,
        operation: @Sendable @escaping () async -> Data?,
        continuation: CheckedContinuation<Data?, Never>
    ) {
        if var entry = inFlight[key] {
            entry.waiters[waiterID] = continuation
            inFlight[key] = entry
            return
        }

        let operationID = UUID()
        let task = Task<Void, Never> {
            let result = await operation()
            self.completeFetch(result, for: key, operationID: operationID)
        }
        inFlight[key] = InFlightEntry(
            id: operationID,
            task: task,
            waiters: [waiterID: continuation]
        )
    }

    private func cancelWaiter(_ waiterID: UUID, for key: String) {
        guard var entry = inFlight[key],
              let continuation = entry.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(returning: nil)
        guard entry.waiters.isEmpty else {
            inFlight[key] = entry
            return
        }
        inFlight[key] = nil
        entry.task.cancel()
    }

    private func completeFetch(_ result: Data?, for key: String, operationID: UUID) {
        guard let entry = inFlight[key], entry.id == operationID else { return }
        inFlight[key] = nil
        for continuation in entry.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func isTemporarilyNegative(_ key: String) -> Bool {
        guard let expiry = negativeUntil[key] else { return false }
        if expiry > Date() { return true }
        negativeUntil.removeValue(forKey: key)
        return false
    }

    private func markTemporarilyNegative(_ key: String) {
        negativeUntil[key] = Date().addingTimeInterval(Self.negativeCacheTTL)
    }

    private static func fetchITunes(term: String) async -> Data? {
        guard !term.isEmpty,
              var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        do {
            let data = try await fetchSearchResponse(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            guard let art = results.first?["artworkUrl100"] as? String else { return nil }
            let hi = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let imgURL = URL(string: hi),
                  let scheme = imgURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  imgURL.host?.isEmpty == false,
                  imgURL.user == nil,
                  imgURL.password == nil else { return nil }
            return await fetchRemoteArtwork(
                from: imgURL,
                maximumBytes: maximumRemoteArtworkBytes
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func fetchSearchResponse(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: remoteArtworkSession,
            maximumBytes: maximumSearchResponseBytes
        )
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let finalURL = http.url,
              let scheme = finalURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              finalURL.host?.isEmpty == false,
              finalURL.user == nil,
              finalURL.password == nil else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }

    private nonisolated static func fetchRemoteArtwork(
        from url: URL,
        maximumBytes: Int
    ) async -> Data? {
        guard maximumBytes > 0 else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await StreamResolverHTTPTransport.data(
                for: request,
                session: remoteArtworkSession,
                maximumBytes: maximumBytes
            )
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let finalURL = http.url,
                  let finalScheme = finalURL.scheme?.lowercased(),
                  finalScheme == "http" || finalScheme == "https",
                  finalURL.host?.isEmpty == false,
                  finalURL.user == nil,
                  finalURL.password == nil else {
                return nil
            }

            if let mime = response.mimeType?.lowercased(),
               !mime.hasPrefix("image/"),
               mime != "application/octet-stream" {
                return nil
            }

            return isImageData(data) ? data : nil
        } catch {
            return nil
        }
    }

    private nonisolated static func isImageData(_ data: Data) -> Bool {
        ArtworkImageCompatibility.isCompleteImage(data)
    }

    nonisolated static func isAnimationContainerCandidate(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        if type.conforms(to: .gif) { return true }
        if type.conforms(to: .png) {
            return pngContainsAnimationControl(data)
        }
        if type.conforms(to: .webP) {
            return webPContainsAnimationChunk(data)
        }
        return false
    }

    private nonisolated static func pngContainsAnimationControl(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                  rawBuffer.count >= 20,
                  bytes[0] == 0x89,
                  bytes[1] == 0x50,
                  bytes[2] == 0x4E,
                  bytes[3] == 0x47,
                  bytes[4] == 0x0D,
                  bytes[5] == 0x0A,
                  bytes[6] == 0x1A,
                  bytes[7] == 0x0A else { return false }

            var offset = 8
            while offset <= rawBuffer.count - 12 {
                let payloadLength = Int(readUInt32BigEndian(bytes, at: offset))
                guard payloadLength <= rawBuffer.count - offset - 12 else { return false }
                let typeOffset = offset + 4
                if matchesFourCC(bytes, at: typeOffset, 0x61, 0x63, 0x54, 0x4C) {
                    return true // acTL
                }
                if matchesFourCC(bytes, at: typeOffset, 0x49, 0x44, 0x41, 0x54)
                    || matchesFourCC(bytes, at: typeOffset, 0x49, 0x45, 0x4E, 0x44) {
                    return false // APNG requires acTL before the first IDAT.
                }
                offset += payloadLength + 12
            }
            return false
        }
    }

    private nonisolated static func webPContainsAnimationChunk(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                  rawBuffer.count >= 20,
                  matchesFourCC(bytes, at: 0, 0x52, 0x49, 0x46, 0x46), // RIFF
                  matchesFourCC(bytes, at: 8, 0x57, 0x45, 0x42, 0x50) else { return false } // WEBP

            let declaredPayloadLength = Int(readUInt32LittleEndian(bytes, at: 4))
            guard declaredPayloadLength <= rawBuffer.count - 8 else { return false }
            let containerEnd = declaredPayloadLength + 8
            var offset = 12
            while offset <= containerEnd - 8 {
                if matchesFourCC(bytes, at: offset, 0x41, 0x4E, 0x49, 0x4D)
                    || matchesFourCC(bytes, at: offset, 0x41, 0x4E, 0x4D, 0x46) {
                    return true // ANIM / ANMF
                }
                let payloadLength = Int(readUInt32LittleEndian(bytes, at: offset + 4))
                guard payloadLength <= containerEnd - offset - 8 else { return false }
                offset += 8 + payloadLength + (payloadLength & 1)
            }
            return false
        }
    }

    private nonisolated static func matchesFourCC(
        _ bytes: UnsafePointer<UInt8>,
        at offset: Int,
        _ a: UInt8,
        _ b: UInt8,
        _ c: UInt8,
        _ d: UInt8
    ) -> Bool {
        bytes[offset] == a
            && bytes[offset + 1] == b
            && bytes[offset + 2] == c
            && bytes[offset + 3] == d
    }

    private nonisolated static func readUInt32BigEndian(
        _ bytes: UnsafePointer<UInt8>,
        at offset: Int
    ) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private nonisolated static func readUInt32LittleEndian(
        _ bytes: UnsafePointer<UInt8>,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// 封面视图:加载到真实封面就显示,否则用程序化封面占位/兜底。
struct TVArtworkView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @AppStorage(PlayerAppearancePreferences.animatedArtworkEnabledKey)
    private var animatedArtworkEnabled = PlayerAppearancePreferences.animatedArtworkEnabledByDefault

    var coverKey: String          // 缓存键(专辑 id)
    var songID: String? = nil
    var coverRef: String? = nil
    var artist: String
    var album: String
    // 程序化兜底参数
    var tint: Color
    var tint2: Color
    var glyph: String
    var placeholderKind: TVArtworkPlaceholderKind = .music
    var size: CGFloat
    var height: CGFloat? = nil
    var radius: CGFloat = 0
    var presentationRole: ArtworkPresentationRole = .staticFirstFrame
    var animationRequiresPlayback = false
    var isPlaying = true
    var isAnimationVisible = true
    var onResolutionChange: (Bool) -> Void = { _ in }

    @State private var image: UIImage? = nil
    @State private var animatedArtworkData: Data? = nil
    @State private var animatedArtworkDescriptor: ArtworkDescriptor? = nil
    @State private var animatedArtworkContentKey: String? = nil
    @State private var animatedArtworkDiskKey: String? = nil
    @State private var loadedArtworkAnimationDiskKey: String? = nil
    @State private var loadedIdentity: String? = nil
    @State private var activeIdentity: String? = nil
    @State private var paletteAppliedIdentity: String? = nil
    @State private var retryRevision = 0
    @State private var animationPolicyRevision = 0

    private var artworkIdentity: String {
        let overrideSuffix = albumArtworkOverrideIdentity.map { "|override:\($0)" } ?? ""
        if !coverKey.isEmpty {
            guard let songID, !songID.isEmpty else { return "album:\(coverKey)\(overrideSuffix)" }
            return "album:\(coverKey)|song:\(songID)|\(coverRef ?? "")\(overrideSuffix)"
        }
        guard let songID, !songID.isEmpty else { return "" }
        return "song:\(songID)|\(coverRef ?? "")"
    }

    private var animationPlaybackPolicy: ArtworkAnimationPolicy {
        ArtworkAnimationPolicy(
            isEnabled: animatedArtworkEnabled,
            presentationRole: presentationRole,
            isVisible: isAnimationVisible,
            isSceneActive: scenePhase == .active,
            requiresPlayback: animationRequiresPlayback,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            playAnimatedImages: playAnimatedImages,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalCondition: Self.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
    }

    private var artworkTaskIdentity: String {
        var components = [
            artworkIdentity,
            String(retryRevision),
            presentationRole.rawValue,
            songSourceAnimationDiskKey,
            albumSourceAnimationDiskKey,
            preferredAnimationDiskKey,
        ]
        guard presentationRole == .animatedHero else {
            return components.joined(separator: "|")
        }
        components.append(contentsOf: [
            String(animatedArtworkEnabled),
            String(isAnimationVisible),
            String(animationRequiresPlayback),
            String(isPlaying),
            String(scenePhase == .active),
            String(reduceMotion),
            String(playAnimatedImages),
            String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            Self.thermalCondition(ProcessInfo.processInfo.thermalState).rawValue,
            String(animationPolicyRevision),
        ])
        return components.joined(separator: "|")
    }

    private var songSourceAnimationDiskKey: String {
        let song = songID.flatMap { store.library.song(id: $0) }
        return songAnimationDiskKey(
            songID: songID,
            sourceID: song?.sourceID,
            coverRef: coverRef,
            sourceRevision: song?.revision
        )
    }

    private var albumSourceAnimationDiskKey: String {
        guard !coverKey.isEmpty else { return "" }
        return [
            "tv-source-v3",
            "album",
            coverKey,
            albumArtworkOverrideIdentity ?? "automatic",
        ].joined(separator: "\u{1F}")
    }

    private var preferredAnimationDiskKey: String {
        if let albumArtworkOverride,
           case .uploaded(let contentID) = albumArtworkOverride {
            return uploadedAnimationDiskKey(contentID: contentID)
        }
        if let albumArtworkOverride,
           case .selectedSong(let selectedSongID) = albumArtworkOverride,
           let selectedSong = store.library.song(id: selectedSongID) {
            return songAnimationDiskKey(for: selectedSong)
        }
        let hasFnMusicCoverReference = FnMusicAPIProtocol.coverID(from: coverRef ?? "") != nil
        if presentationRole != .animatedHero,
           !albumSourceAnimationDiskKey.isEmpty,
           !hasFnMusicCoverReference {
            return albumSourceAnimationDiskKey
        }
        return !songSourceAnimationDiskKey.isEmpty
            ? songSourceAnimationDiskKey
            : albumSourceAnimationDiskKey
    }

    private func songAnimationDiskKey(for song: Song) -> String {
        songAnimationDiskKey(
            songID: song.id,
            sourceID: song.sourceID,
            coverRef: song.coverArtFileName,
            sourceRevision: song.revision
        )
    }

    private func songAnimationDiskKey(
        songID: String?,
        sourceID: String?,
        coverRef: String?,
        sourceRevision: String?
    ) -> String {
        guard let songID, !songID.isEmpty else { return "" }
        let components = [
            "tv-source-v3",
            "song",
            sourceID ?? "",
            songID,
            coverRef ?? "",
            sourceRevision ?? "",
        ]
        return components.joined(separator: "\u{1F}")
    }

    private func uploadedAnimationDiskKey(contentID: String) -> String {
        ["tv-source-v3", "upload", contentID].joined(separator: "\u{1F}")
    }

    private var paletteKey: String {
        !coverKey.isEmpty ? coverKey : "song:\(songID ?? "")"
    }

    private var albumArtworkOverride: LibraryArtworkOverrideResolution? {
        guard !coverKey.isEmpty else { return nil }
        return store.library.artworkOverrideResolution(
            for: LibraryArtworkOwner(kind: .album, id: coverKey),
            eligibleSongs: store.library.songs(forAlbum: coverKey)
        )
    }

    private var albumArtworkOverrideIdentity: String? {
        guard let albumArtworkOverride else { return nil }
        switch albumArtworkOverride {
        case .automatic: return "automatic:\(store.library.artworkOverrideRevision)"
        case .selectedSong(let songID):
            return "song:\(songID):\(store.library.artworkOverrideRevision)"
        case .uploaded(let contentID):
            return "upload:\(contentID):\(store.library.artworkOverrideRevision)"
        }
    }

    var body: some View {
        let h = height ?? size
        ZStack {
            if let image {
                if let animatedArtworkData, let animatedArtworkDescriptor {
                    AnimatedArtworkDataView(
                        data: animatedArtworkData,
                        descriptor: animatedArtworkDescriptor,
                        cacheKey: animatedArtworkContentKey ?? artworkIdentity,
                        presentationRole: presentationRole,
                        isVisible: isAnimationVisible,
                        requiresPlayback: animationRequiresPlayback,
                        isPlaying: isPlaying,
                        maximumPixelSize: min(1_536, max(1, Int(max(size, h) * 2)))
                    ) {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                TVMusicPlaceholder(
                    tint: tint,
                    tint2: tint2,
                    kind: placeholderKind,
                    size: size,
                    height: h
                )
            }
        }
        .frame(width: size, height: h)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(TVColor.cardBorder, lineWidth: 1)
        }
        .task(id: artworkTaskIdentity) {
            let taskIdentity = artworkTaskIdentity
            let identity = artworkIdentity
            let currentAnimationKey = preferredAnimationDiskKey
            if !animationPlaybackPolicy.shouldAnimate {
                clearAnimatedArtworkState()
            }
            guard !identity.isEmpty else {
                activeIdentity = nil
                loadedIdentity = nil
                paletteAppliedIdentity = nil
                image = nil
                loadedArtworkAnimationDiskKey = nil
                clearAnimatedArtworkState()
                onResolutionChange(false)
                return
            }
            if loadedIdentity == identity,
               image != nil,
               paletteAppliedIdentity == identity,
               loadedArtworkAnimationDiskKey == currentAnimationKey {
                guard animationPlaybackPolicy.shouldAnimate else { return }
                if await resolveAnimatedArtwork(
                    candidateData: nil,
                    identity: identity,
                    taskIdentity: taskIdentity,
                    diskKey: currentAnimationKey
                ) {
                    return
                }
            }
            // 身份变了:先清掉上一张封面,回到程序化占位再取新图。
            let identityChanged = activeIdentity != identity
            activeIdentity = identity
            if identityChanged {
                paletteAppliedIdentity = nil
                image = nil
                loadedArtworkAnimationDiskKey = nil
                clearAnimatedArtworkState()
            }

            if await acceptOriginalHeroArtwork(
                identity: identity,
                taskIdentity: taskIdentity,
                diskKey: currentAnimationKey
            ) {
                return
            }

            if let albumArtworkOverride {
                switch albumArtworkOverride {
                case .uploaded(let contentID):
                    if let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID),
                       await accept(
                        data,
                        identity: identity,
                        taskIdentity: taskIdentity,
                        paletteKey: paletteKey,
                        animationDiskKey: uploadedAnimationDiskKey(contentID: contentID),
                        animationCandidateIsOriginal: true
                       ) {
                        return
                    }
                case .selectedSong(let selectedSongID):
                    if let selectedSong = store.library.song(id: selectedSongID) {
                        let client = store.fnMusicClient(for: selectedSong.sourceID)
                        if let data = await TVArtworkLoader.shared.songCover(
                            songID: selectedSong.id,
                            coverRef: selectedSong.coverArtFileName,
                            fnMusicSourceID: selectedSong.sourceID,
                            fnMusicClient: client,
                            animationCacheKey: songAnimationDiskKey(for: selectedSong)
                        ), await accept(
                            data,
                            identity: identity,
                            taskIdentity: taskIdentity,
                            paletteKey: paletteKey,
                            animationDiskKey: songAnimationDiskKey(for: selectedSong)
                        ) {
                            return
                        }
                    }
                case .automatic:
                    break
                }
            }

            let hasFnMusicCoverReference = FnMusicAPIProtocol.coverID(from: coverRef ?? "") != nil
            if presentationRole != .animatedHero,
               !coverKey.isEmpty, !hasFnMusicCoverReference {
                // ① 优先使用已同步到本地的准确专辑封面。
                if let cached = await MetadataAssetStore.shared.cachedAlbumCover(
                    forAlbumID: coverKey
                ), let data = await TVArtworkLoader.shared.preparedAlbumArtwork(
                    cached,
                    albumID: coverKey,
                    animationCacheKey: albumSourceAnimationDiskKey
                ),
                   await accept(
                    data,
                    identity: identity,
                    taskIdentity: taskIdentity,
                    paletteKey: paletteKey,
                    animationDiskKey: albumSourceAnimationDiskKey
                   ) {
                    return
                }
            }
            if let songID, !songID.isEmpty {
                // ② 再查歌曲自身缓存/安全远程引用，避免准确散曲封面被模糊专辑搜索覆盖。
                let fnMusicSourceID = store.library.song(id: songID)?.sourceID
                let fnMusicClient = fnMusicSourceID.flatMap(store.fnMusicClient(for:))
                let songAnimationKey = songSourceAnimationDiskKey
                if let data = await TVArtworkLoader.shared.songCover(
                    songID: songID,
                    coverRef: coverRef,
                    fnMusicSourceID: fnMusicSourceID,
                    fnMusicClient: fnMusicClient,
                    animationCacheKey: songAnimationKey
                ), await accept(
                    data,
                    identity: identity,
                    taskIdentity: taskIdentity,
                    paletteKey: "song:\(songID)",
                    animationDiskKey: songAnimationKey,
                    songScoped: true
                ) {
                    return
                }
            }
            if presentationRole == .animatedHero,
               !coverKey.isEmpty, !hasFnMusicCoverReference,
               let cached = await MetadataAssetStore.shared.cachedAlbumCover(
                forAlbumID: coverKey
               ), let data = await TVArtworkLoader.shared.preparedAlbumArtwork(
                cached,
                albumID: coverKey,
                animationCacheKey: albumSourceAnimationDiskKey
               ),
               await accept(
                data,
                identity: identity,
                taskIdentity: taskIdentity,
                paletteKey: paletteKey,
                animationDiskKey: albumSourceAnimationDiskKey
               ) {
                return
            }
            if !coverKey.isEmpty, !hasFnMusicCoverReference {
                // ③ 本地准确来源都没有时，最后按 (艺术家, 专辑) 在线搜索封面。
                // 飞牛引用失败时保留占位并重试，不能让模糊搜索永久盖住准确源封面。
                if let data = await TVArtworkLoader.shared.cover(
                    key: coverKey,
                    artist: artist,
                    album: album
                ), await accept(
                    data,
                    identity: identity,
                    taskIdentity: taskIdentity,
                    paletteKey: paletteKey,
                    animationDiskKey: albumSourceAnimationDiskKey
                ) {
                    return
                }
            }
            guard activeIdentity == identity,
                  artworkTaskIdentity == taskIdentity,
                  !Task.isCancelled else { return }
            loadedIdentity = identity
            onResolutionChange(false)
            // A timeout or offline response is only a short-lived negative.
            // Keep a visible card recoverable even when its identity does not
            // change and no external cache notification arrives.
            try? await Task.sleep(
                nanoseconds: UInt64(TVArtworkLoader.negativeCacheTTL * 1_000_000_000)
            )
            guard activeIdentity == identity,
                  artworkTaskIdentity == taskIdentity,
                  image == nil,
                  !Task.isCancelled else { return }
            retryRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard notificationMatchesCurrentArtwork(note) else { return }
            forceArtworkReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard notificationMatchesCurrentArtwork(note) else { return }
            forceArtworkReload(removingAnimationEntry: true)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            animationPolicyRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            animationPolicyRevision &+= 1
        }
        .onChange(of: image != nil) { _, isResolved in
            if isResolved { onResolutionChange(true) }
        }
    }

    private func forceArtworkReload(removingAnimationEntry: Bool = false) {
        let candidateDiskKeys: [String?] = [
            animatedArtworkDiskKey,
            loadedArtworkAnimationDiskKey,
            preferredAnimationDiskKey,
            songSourceAnimationDiskKey,
            albumSourceAnimationDiskKey,
        ]
        let diskKeys = Set<String>(candidateDiskKeys.compactMap { key in
            guard let key, !key.isEmpty else { return nil }
            return key
        })
        let invalidatedIdentity = artworkIdentity
        loadedIdentity = nil
        activeIdentity = nil
        paletteAppliedIdentity = nil
        image = nil
        loadedArtworkAnimationDiskKey = nil
        clearAnimatedArtworkState()
        if removingAnimationEntry, !diskKeys.isEmpty {
            Task { @MainActor in
                for diskKey in diskKeys {
                    await TVArtworkLoader.shared.removeAnimationEntry(forKey: diskKey)
                }
                guard artworkIdentity == invalidatedIdentity else { return }
                retryRevision &+= 1
            }
        } else {
            retryRevision &+= 1
        }
    }

    private func notificationMatchesCurrentArtwork(_ note: Notification) -> Bool {
        if note.userInfo?["all"] as? Bool == true { return true }
        var relevantSongIDs = Set<String>()
        if let songID, !songID.isEmpty {
            relevantSongIDs.insert(songID)
        }
        if let albumArtworkOverride,
           case .selectedSong(let selectedSongID) = albumArtworkOverride {
            relevantSongIDs.insert(selectedSongID)
        }
        if let notifiedSongID = note.object as? String,
           relevantSongIDs.contains(notifiedSongID) {
            return true
        }
        if let notifiedSongID = note.userInfo?["songID"] as? String,
           relevantSongIDs.contains(notifiedSongID) {
            return true
        }
        if let notifiedSongIDs = note.userInfo?["songIDs"] as? [String],
           !relevantSongIDs.isDisjoint(with: notifiedSongIDs) {
            return true
        }
        let tokens = note.userInfo?["tokens"] as? [String] ?? []
        if !coverKey.isEmpty, tokens.contains(coverKey) { return true }
        if let coverRef, !coverRef.isEmpty {
            if note.object as? String == coverRef || tokens.contains(coverRef) { return true }
        }
        return false
    }

    /// UIImage 成功创建后再提色；图片与颜色两次回填都校验共享的 activeIdentity，
    /// 避免滚动复用或快速切歌时慢请求把上一张封面写到当前页面。
    @MainActor
    private func accept(
        _ data: Data,
        identity: String,
        taskIdentity: String,
        paletteKey: String,
        animationDiskKey: String,
        animationCandidateIsOriginal: Bool = false,
        songScoped: Bool = false
    ) async -> Bool {
        guard let ui = UIImage(data: data), activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else { return false }
        image = ui
        loadedIdentity = identity
        loadedArtworkAnimationDiskKey = animationDiskKey
        _ = await resolveAnimatedArtwork(
            candidateData: data,
            candidateIsOriginal: animationCandidateIsOriginal,
            identity: identity,
            taskIdentity: taskIdentity,
            diskKey: animationDiskKey
        )

        guard activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else { return false }
        guard let palette = await TVArtworkPaletteLoader.shared.palette(
            for: data,
            artworkKey: paletteKey
        ), activeIdentity == identity,
           artworkTaskIdentity == taskIdentity,
           !Task.isCancelled else { return true }
        if songScoped, let songID, !songID.isEmpty {
            store.applyArtworkPalette(palette, forSongID: songID)
        } else if !coverKey.isEmpty {
            store.applyArtworkPalette(palette, forAlbumID: coverKey)
        } else if let songID, !songID.isEmpty {
            store.applyArtworkPalette(palette, forSongID: songID)
        }
        paletteAppliedIdentity = identity
        return true
    }

    @MainActor
    private func acceptOriginalHeroArtwork(
        identity: String,
        taskIdentity: String,
        diskKey: String
    ) async -> Bool {
        guard presentationRole == .animatedHero,
              animationPlaybackPolicy.shouldAnimate,
              !diskKey.isEmpty else { return false }

        let cacheWasConclusive = await resolveAnimatedArtwork(
            candidateData: nil,
            identity: identity,
            taskIdentity: taskIdentity,
            diskKey: diskKey
        )
        guard animationPlaybackPolicy.shouldAnimate,
              activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else { return false }

        let data: Data
        let candidateIsOriginal: Bool
        if cacheWasConclusive {
            guard let cachedData = animatedArtworkData else { return false }
            data = cachedData
            candidateIsOriginal = false
        } else {
            guard let originalData = await originalHeroArtworkData(diskKey: diskKey),
                  animationPlaybackPolicy.shouldAnimate,
                  activeIdentity == identity,
                  artworkTaskIdentity == taskIdentity,
                  !Task.isCancelled else { return false }
            data = originalData
            candidateIsOriginal = true
        }

        if candidateIsOriginal {
            _ = await resolveAnimatedArtwork(
                candidateData: data,
                candidateIsOriginal: true,
                identity: identity,
                taskIdentity: taskIdentity,
                diskKey: diskKey
            )
        }
        guard let displayData = await TVArtworkLoader.shared.preparedHeroFallback(data),
              animationPlaybackPolicy.shouldAnimate,
              activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else { return false }

        let usesAlbumOverride: Bool
        if let albumArtworkOverride {
            switch albumArtworkOverride {
            case .uploaded, .selectedSong:
                usesAlbumOverride = true
            case .automatic:
                usesAlbumOverride = false
            }
        } else {
            usesAlbumOverride = false
        }
        let targetPaletteKey = usesAlbumOverride || songID?.isEmpty != false
            ? paletteKey
            : "song:\(songID ?? "")"
        return await accept(
            displayData,
            identity: identity,
            taskIdentity: taskIdentity,
            paletteKey: targetPaletteKey,
            animationDiskKey: diskKey,
            songScoped: !usesAlbumOverride && songID?.isEmpty == false
        )
    }

    @MainActor
    private func originalHeroArtworkData(diskKey: String) async -> Data? {
        if let albumArtworkOverride {
            switch albumArtworkOverride {
            case .uploaded(let contentID):
                return MetadataAssetStore.shared.customArtworkData(contentID: contentID)
            case .selectedSong(let selectedSongID):
                guard let selectedSong = store.library.song(id: selectedSongID) else {
                    return nil
                }
                return await TVArtworkLoader.shared.originalAnimationCandidate(
                    songID: selectedSong.id,
                    coverRef: selectedSong.coverArtFileName,
                    fnMusicSourceID: selectedSong.sourceID,
                    fnMusicClient: store.fnMusicClient(for: selectedSong.sourceID),
                    requestKey: diskKey
                )
            case .automatic:
                break
            }
        }

        guard let songID, !songID.isEmpty else { return nil }
        let sourceID = store.library.song(id: songID)?.sourceID
        return await TVArtworkLoader.shared.originalAnimationCandidate(
            songID: songID,
            coverRef: coverRef,
            fnMusicSourceID: sourceID,
            fnMusicClient: sourceID.flatMap(store.fnMusicClient(for:)),
            requestKey: diskKey
        )
    }

    /// Returns true when the animation cache had a conclusive positive or
    /// negative result. A false result asks the caller to reload the base data,
    /// which is needed for durable user artwork that has not been inspected yet.
    @MainActor
    private func resolveAnimatedArtwork(
        candidateData: Data?,
        candidateIsOriginal: Bool = false,
        identity: String,
        taskIdentity: String,
        diskKey: String
    ) async -> Bool {
        guard animationPlaybackPolicy.shouldAnimate,
              !diskKey.isEmpty,
              activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else {
            clearAnimatedArtworkState()
            return true
        }
        if animatedArtworkDiskKey == diskKey,
           animatedArtworkData != nil,
           animatedArtworkDescriptor != nil {
            return true
        }

        let cached = await TVArtworkLoader.shared.cachedAnimation(forKey: diskKey)
        guard animationPlaybackPolicy.shouldAnimate,
              activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else {
            clearAnimatedArtworkState()
            return true
        }

        let data: Data
        let cameFromDisk: Bool
        var assetGeneration: String?
        switch cached {
        case .asset(let record):
            data = record.data
            cameFromDisk = true
            assetGeneration = record.generation
        case .negative:
            clearAnimatedArtworkState()
            return true
        case nil:
            guard let candidateData else { return false }
            guard TVArtworkLoader.isAnimationContainerCandidate(candidateData) else {
                guard candidateIsOriginal else {
                    clearAnimatedArtworkState()
                    return false
                }
                await TVArtworkLoader.shared.recordStaticAnimationResult(forKey: diskKey)
                clearAnimatedArtworkState()
                return true
            }
            data = candidateData
            cameFromDisk = false
        }

        if cameFromDisk,
           let assetGeneration,
           let descriptor = await TVArtworkLoader.shared.cachedAnimationDescriptor(
            forKey: diskKey,
            generation: assetGeneration
           ) {
            guard animationPlaybackPolicy.shouldAnimate,
                  activeIdentity == identity,
                  artworkTaskIdentity == taskIdentity,
                  !Task.isCancelled else {
                clearAnimatedArtworkState()
                return true
            }
            animatedArtworkData = data
            animatedArtworkDescriptor = descriptor
            animatedArtworkDiskKey = diskKey
            animatedArtworkContentKey = "\(diskKey)|\(data.count)|\(data.hashValue)"
            return true
        }

        guard animationPlaybackPolicy.shouldAnimate else {
            clearAnimatedArtworkState()
            return true
        }
        let inspectionTask = Task.detached(priority: .utility) {
            ArtworkImageCompatibility.inspect(data)
        }
        let descriptor = await withTaskCancellationHandler {
            await inspectionTask.value
        } onCancel: {
            inspectionTask.cancel()
        }
        guard animationPlaybackPolicy.shouldAnimate,
              activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else {
            clearAnimatedArtworkState()
            return true
        }
        guard let descriptor, descriptor.isAnimated else {
            await TVArtworkLoader.shared.recordStaticAnimationResult(
                forKey: diskKey,
                matchingGeneration: assetGeneration
            )
            clearAnimatedArtworkState()
            return true
        }

        if !cameFromDisk {
            assetGeneration = await TVArtworkLoader.shared.cacheValidatedAnimation(
                data,
                forKey: diskKey
            )
        }
        if let assetGeneration {
            await TVArtworkLoader.shared.cacheAnimationDescriptor(
                descriptor,
                forKey: diskKey,
                generation: assetGeneration
            )
        }
        guard animationPlaybackPolicy.shouldAnimate,
              activeIdentity == identity,
              artworkTaskIdentity == taskIdentity,
              !Task.isCancelled else {
            clearAnimatedArtworkState()
            return true
        }
        animatedArtworkData = data
        animatedArtworkDescriptor = descriptor
        animatedArtworkDiskKey = diskKey
        animatedArtworkContentKey = "\(diskKey)|\(data.count)|\(data.hashValue)"
        return true
    }

    private func clearAnimatedArtworkState() {
        animatedArtworkData = nil
        animatedArtworkDescriptor = nil
        animatedArtworkContentKey = nil
        animatedArtworkDiskKey = nil
    }

    private nonisolated static func thermalCondition(
        _ state: ProcessInfo.ThermalState
    ) -> ArtworkThermalCondition {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }

    init(
        album a: TVAlbum,
        size: CGFloat,
        height: CGFloat? = nil,
        radius: CGFloat = 0,
        presentationRole: ArtworkPresentationRole = .staticFirstFrame,
        animationRequiresPlayback: Bool = false,
        isPlaying: Bool = true,
        isAnimationVisible: Bool = true,
        onResolutionChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.coverKey = a.id; self.artist = a.artist; self.album = a.title
        self.tint = a.tint; self.tint2 = a.tint2; self.glyph = a.glyph
        self.size = size; self.height = height; self.radius = radius
        self.presentationRole = presentationRole
        self.animationRequiresPlayback = animationRequiresPlayback
        self.isPlaying = isPlaying
        self.isAnimationVisible = isAnimationVisible
        self.onResolutionChange = onResolutionChange
    }
    init(coverKey: String, artist: String, album: String,
         songID: String? = nil, coverRef: String? = nil,
         tint: Color, tint2: Color,
         glyph: String, placeholderKind: TVArtworkPlaceholderKind = .music,
         size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0,
         presentationRole: ArtworkPresentationRole = .staticFirstFrame,
         animationRequiresPlayback: Bool = false,
         isPlaying: Bool = true,
         isAnimationVisible: Bool = true,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        self.coverKey = coverKey; self.artist = artist; self.album = album
        self.songID = songID; self.coverRef = coverRef
        self.tint = tint; self.tint2 = tint2; self.glyph = glyph
        self.placeholderKind = placeholderKind
        self.size = size; self.height = height; self.radius = radius
        self.presentationRole = presentationRole
        self.animationRequiresPlayback = animationRequiresPlayback
        self.isPlaying = isPlaying
        self.isAnimationVisible = isAnimationVisible
        self.onResolutionChange = onResolutionChange
    }
}
#endif
