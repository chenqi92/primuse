#if os(tvOS)
import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import PrimuseKit

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

    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var negativeUntil: [String: Date] = [:]
    static let negativeCacheTTL: TimeInterval = 5 * 60
    private static let maximumRemoteArtworkBytes = 8 * 1024 * 1024
    private static let maximumSearchResponseBytes = 1 * 1024 * 1024
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
        guard !key.isEmpty, !(artist.isEmpty && album.isEmpty) else { return nil }
        let disk = diskURL(key)
        if let data = try? Data(contentsOf: disk) {
            if Self.isImageData(data) { return data }
            // Old builds could persist an HTTP error body with a .jpg suffix.
            // It is disposable cache data, so remove it and recover online.
            try? FileManager.default.removeItem(at: disk)
        }
        if isTemporarilyNegative(key) { return nil }
        if let t = inFlight[key] { return await t.value }
        let task = Task<Data?, Never> {
            let data = await Self.fetchITunes(term: "\(artist) \(album)".trimmingCharacters(in: .whitespaces))
            if let data { try? data.write(to: disk, options: .atomic) }
            return data
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if result == nil {
            markTemporarilyNegative(key)
        } else {
            negativeUntil.removeValue(forKey: key)
        }
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
        fnMusicClient: FnMusicServiceClient? = nil
    ) async -> Data? {
        guard !songID.isEmpty else { return nil }
        let ref = coverRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fnMusicRequestKey = FnMusicAPIProtocol.coverID(from: ref).map { _ in
            "fnmusic-cover:\(fnMusicSourceID ?? songID)|\(ref)"
        }

        if let fnMusicRequestKey {
            let disk = diskURL(fnMusicRequestKey)
            if let data = try? Data(contentsOf: disk) {
                if Self.isImageData(data) {
                    let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID)
                    if cached != data {
                        await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
                    }
                    return data
                }
                try? FileManager.default.removeItem(at: disk)
            }
        } else if let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) {
            return cached
        }

        guard !ref.isEmpty else { return nil }

        if MetadataAssetStore.shared.isLegacyLocalRef(ref),
           let data = MetadataAssetStore.shared.readCoverData(named: ref),
           Self.isImageData(data) {
            await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
            return data
        }

        if let fnMusicRequestKey {
            guard let fnMusicClient else { return nil }
            if isTemporarilyNegative(fnMusicRequestKey) { return nil }
            let task: Task<Data?, Never>
            if let running = inFlight[fnMusicRequestKey] {
                task = running
            } else {
                task = Task {
                    guard !Task.isCancelled,
                          let data = try? await fnMusicClient.coverData(reference: ref),
                          !Task.isCancelled,
                          Self.isImageData(data) else {
                        return nil
                    }
                    return data
                }
                inFlight[fnMusicRequestKey] = task
            }

            let result = await task.value
            inFlight[fnMusicRequestKey] = nil
            guard let result else {
                markTemporarilyNegative(fnMusicRequestKey)
                return nil
            }
            negativeUntil.removeValue(forKey: fnMusicRequestKey)
            try? result.write(to: diskURL(fnMusicRequestKey), options: .atomic)
            await MetadataAssetStore.shared.cacheCover(result, forSongID: songID)
            return result
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
        let task: Task<Data?, Never>
        if let running = inFlight[requestKey] {
            task = running
        } else {
            task = Task {
                await Self.fetchRemoteArtwork(from: url)
            }
            inFlight[requestKey] = task
        }

        let result = await task.value
        inFlight[requestKey] = nil
        guard let result else {
            markTemporarilyNegative(requestKey)
            return nil
        }
        negativeUntil.removeValue(forKey: requestKey)
        await MetadataAssetStore.shared.cacheCover(result, forSongID: songID)
        return result
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
            return await fetchRemoteArtwork(from: imgURL)
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

    private nonisolated static func fetchRemoteArtwork(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await StreamResolverHTTPTransport.data(
                for: request,
                session: remoteArtworkSession,
                maximumBytes: maximumRemoteArtworkBytes
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
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

/// 封面视图:加载到真实封面就显示,否则用程序化封面占位/兜底。
struct TVArtworkView: View {
    @Environment(TVStore.self) private var store

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
    var onResolutionChange: (Bool) -> Void = { _ in }

    @State private var image: UIImage? = nil
    @State private var loadedIdentity: String? = nil
    @State private var activeIdentity: String? = nil
    @State private var paletteAppliedIdentity: String? = nil
    @State private var retryRevision = 0

    private var artworkIdentity: String {
        if !coverKey.isEmpty {
            guard let songID, !songID.isEmpty else { return "album:\(coverKey)" }
            return "album:\(coverKey)|song:\(songID)|\(coverRef ?? "")"
        }
        guard let songID, !songID.isEmpty else { return "" }
        return "song:\(songID)|\(coverRef ?? "")"
    }

    private var paletteKey: String {
        !coverKey.isEmpty ? coverKey : "song:\(songID ?? "")"
    }

    var body: some View {
        let h = height ?? size
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
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
        .task(id: "\(artworkIdentity)|\(retryRevision)") {
            let identity = artworkIdentity
            guard !identity.isEmpty else {
                activeIdentity = nil
                loadedIdentity = nil
                paletteAppliedIdentity = nil
                image = nil
                onResolutionChange(false)
                return
            }
            guard loadedIdentity != identity || image == nil
                    || paletteAppliedIdentity != identity else { return }
            // 身份变了:先清掉上一张封面,回到程序化占位再取新图。
            activeIdentity = identity
            paletteAppliedIdentity = nil
            image = nil

            let hasFnMusicCoverReference = FnMusicAPIProtocol.coverID(from: coverRef ?? "") != nil
            if !coverKey.isEmpty, !hasFnMusicCoverReference {
                // ① 优先使用已同步到本地的准确专辑封面。
                if let data = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: coverKey),
                   await accept(data, identity: identity, paletteKey: paletteKey) {
                    return
                }
            }
            if let songID, !songID.isEmpty {
                // ② 再查歌曲自身缓存/安全远程引用，避免准确散曲封面被模糊专辑搜索覆盖。
                let fnMusicSourceID = store.library.song(id: songID)?.sourceID
                let fnMusicClient = fnMusicSourceID.flatMap(store.fnMusicClient(for:))
                if let data = await TVArtworkLoader.shared.songCover(
                    songID: songID,
                    coverRef: coverRef,
                    fnMusicSourceID: fnMusicSourceID,
                    fnMusicClient: fnMusicClient
                ), await accept(
                    data,
                    identity: identity,
                    paletteKey: "song:\(songID)",
                    songScoped: true
                ) {
                    return
                }
            }
            if !coverKey.isEmpty, !hasFnMusicCoverReference {
                // ③ 本地准确来源都没有时，最后按 (艺术家, 专辑) 在线搜索封面。
                // 飞牛引用失败时保留占位并重试，不能让模糊搜索永久盖住准确源封面。
                if let data = await TVArtworkLoader.shared.cover(
                    key: coverKey,
                    artist: artist,
                    album: album
                ), await accept(data, identity: identity, paletteKey: paletteKey) {
                    return
                }
            }
            guard activeIdentity == identity, !Task.isCancelled else { return }
            loadedIdentity = identity
            onResolutionChange(false)
            // A timeout or offline response is only a short-lived negative.
            // Keep a visible card recoverable even when its identity does not
            // change and no external cache notification arrives.
            try? await Task.sleep(
                nanoseconds: UInt64(TVArtworkLoader.negativeCacheTTL * 1_000_000_000)
            )
            guard activeIdentity == identity, image == nil, !Task.isCancelled else { return }
            retryRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard notificationMatchesCurrentArtwork(note) else { return }
            forceArtworkReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard notificationMatchesCurrentArtwork(note) else { return }
            forceArtworkReload()
        }
        .onChange(of: image != nil) { _, isResolved in
            if isResolved { onResolutionChange(true) }
        }
    }

    private func forceArtworkReload() {
        loadedIdentity = nil
        paletteAppliedIdentity = nil
        image = nil
        retryRevision &+= 1
    }

    private func notificationMatchesCurrentArtwork(_ note: Notification) -> Bool {
        if note.userInfo?["all"] as? Bool == true { return true }
        if let songID, !songID.isEmpty {
            if note.object as? String == songID { return true }
            if note.userInfo?["songID"] as? String == songID { return true }
            if (note.userInfo?["songIDs"] as? [String])?.contains(songID) == true { return true }
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
        paletteKey: String,
        songScoped: Bool = false
    ) async -> Bool {
        guard let ui = UIImage(data: data), activeIdentity == identity,
              !Task.isCancelled else { return false }
        image = ui
        loadedIdentity = identity

        guard let palette = await TVArtworkPaletteLoader.shared.palette(
            for: data,
            artworkKey: paletteKey
        ), activeIdentity == identity, !Task.isCancelled else { return true }
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

    init(
        album a: TVAlbum,
        size: CGFloat,
        height: CGFloat? = nil,
        radius: CGFloat = 0,
        onResolutionChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.coverKey = a.id; self.artist = a.artist; self.album = a.title
        self.tint = a.tint; self.tint2 = a.tint2; self.glyph = a.glyph
        self.size = size; self.height = height; self.radius = radius
        self.onResolutionChange = onResolutionChange
    }
    init(coverKey: String, artist: String, album: String,
         songID: String? = nil, coverRef: String? = nil,
         tint: Color, tint2: Color,
         glyph: String, placeholderKind: TVArtworkPlaceholderKind = .music,
         size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        self.coverKey = coverKey; self.artist = artist; self.album = album
        self.songID = songID; self.coverRef = coverRef
        self.tint = tint; self.tint2 = tint2; self.glyph = glyph
        self.placeholderKind = placeholderKind
        self.size = size; self.height = height; self.radius = radius
        self.onResolutionChange = onResolutionChange
    }
}
#endif
