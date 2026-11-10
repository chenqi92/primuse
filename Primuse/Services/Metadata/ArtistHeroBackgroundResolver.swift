#if canImport(CoreGraphics) && canImport(ImageIO)
import Foundation
import CoreGraphics
import ImageIO
import MusicKit
import PrimuseKit

/// MusicKit 的背景色只用于与当前照片一致的官方封面；本地取色始终可独立回退。
actor ArtistHeroBackgroundResolver {
    static let shared = ArtistHeroBackgroundResolver()

    struct CatalogArtwork: Sendable {
        let color: ArtistHeroArtworkColor
        let signature: ArtistHeroPhotoSignature
    }

    typealias CatalogLookup = @Sendable (String) async -> CatalogArtwork?

    private struct CacheEntry {
        let color: ArtistHeroArtworkColor?
        let expires: Date
    }

    private let lookup: CatalogLookup
    private var cache: [String: CacheEntry] = [:]
    private var recency: [String] = []
    private var pending: [String: Task<ArtistHeroArtworkColor?, Never>] = [:]

    // 只使用当前进程内的 MusicKit 结果，不读取旧版网页抓取的颜色或名称图片缓存。
    init(lookup: @escaping CatalogLookup = ArtistHeroBackgroundResolver.lookupCatalogArtwork) {
        self.lookup = lookup
    }

    func resolve(artistName: String, image: CGImage, exifOrientation: Int32 = 1,
                 allowNetwork: Bool) async -> ArtistHeroArtworkColor? {
        let name = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160, !Task.isCancelled,
              let signature = await Task.detached(priority: .utility, operation: {
                  ArtistHeroPhotoVerification.signature(image: image, exifOrientation: exifOrientation)
              }).value else { return nil }
        let key = ArtistHeroMetadataPolicy.nameKey(name) + "\u{1F}" + signature.cacheToken
        if let entry = cache[key], entry.expires > Date() {
            touch(key)
            return entry.color
        }
        guard allowNetwork, !Task.isCancelled else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while true {
            guard !Task.isCancelled else { return nil }
            if let entry = cache[key], entry.expires > Date() {
                touch(key)
                return entry.color
            }
            if let task = pending[key] {
                let color = await task.value
                return Task.isCancelled ? nil : color
            }
            if pending.count < 2 { break }
            guard ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        let lookup = lookup
        let task = Task<ArtistHeroArtworkColor?, Never> {
            guard let artwork = await lookup(name),
                  ArtistHeroPhotoVerification.matches(signature, artwork.signature),
                  [artwork.color.red, artwork.color.green, artwork.color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            return artwork.color
        }
        pending[key] = task
        let color = await task.value
        pending[key] = nil
        cache[key] = CacheEntry(color: color, expires: Date().addingTimeInterval(color == nil ? 300 : 86_400))
        touch(key)
        while recency.count > 48 { cache[recency.removeFirst()] = nil }
        return Task.isCancelled ? nil : color
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func lookupCatalogArtwork(name: String) async -> CatalogArtwork? {
        guard MusicAuthorization.currentStatus == .authorized, !Task.isCancelled else { return nil }
        var request = MusicCatalogSearchRequest(term: name, types: [MusicKit.Artist.self])
        request.limit = 10
        guard let artists = try? await Array(request.response().artists),
              let index = AppleMusicCatalogContinuationPolicy.uniqueArtistMatchIndex(name: name, in: artists.map(\.name)),
              let artwork = artists[index].artwork,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = artwork.backgroundColor?.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3,
              let url = artwork.url(width: 384, height: 384),
              ArtistHeroMetadataPolicy.isArtworkURL(url), !Task.isCancelled else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 7
        let session = URLSession(configuration: configuration, delegate: ArtistHeroArtworkRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let finalURL = response.url, ArtistHeroMetadataPolicy.isArtworkURL(finalURL),
                  response.mimeType?.hasPrefix("image/") == true,
                  response.expectedContentLength <= 2_000_000 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < 2_000_000 else { return nil }
                data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary),
                  let signature = ArtistHeroPhotoVerification.signature(image: image) else { return nil }
            return CatalogArtwork(color: ArtistHeroArtworkColor(
                red: Double(components[0]), green: Double(components[1]), blue: Double(components[2])
            ), signature: signature)
        } catch { return nil }
    }
}

private final class ArtistHeroArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
