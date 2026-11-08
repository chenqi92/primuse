import Foundation

/// A cached list portrait is not proof that a detail-sized source request ran.
public enum ArtistArtworkResolutionPolicy {
    public static func appleMusicCacheID(artistID: String) -> String {
        "artist-apple-music-v1\u{1F}" + artistID
    }

    public static func requestedPixels(for maximumPixels: Int) -> Int {
        maximumPixels > SubsonicArtworkPolicy.thumbnailPixels
            ? SubsonicArtworkPolicy.fullResolutionPixels
            : SubsonicArtworkPolicy.thumbnailPixels
    }

    /// Keep legacy thumbnails available, while separating newly fetched detail bytes.
    public static func cacheID(baseID: String, maximumPixels: Int) -> String {
        requestedPixels(for: maximumPixels) == SubsonicArtworkPolicy.thumbnailPixels
            ? baseID : "artist-full-v1\u{1F}" + baseID
    }

    public struct Result: Sendable {
        public let data: Data
        /// May be shown offline, but must not populate the requested full-quality memory key.
        public let isProvisional: Bool
    }

    /// Used by both source-owned portraits and the explicit catalog scraper.
    /// Cancellation must not publish/cache a result from a retired request.
    public static func resolve(
        cached: @Sendable () async -> Data?,
        fetch: @Sendable () async -> Data?,
        store: @Sendable (Data) async -> Void,
        fallback: @Sendable () async -> Data?
    ) async -> Result? {
        guard !Task.isCancelled else { return nil }
        if let data = await cached() {
            guard !Task.isCancelled else { return nil }
            return Result(data: data, isProvisional: false)
        }
        guard !Task.isCancelled else { return nil }
        if let data = await fetch() {
            guard !Task.isCancelled else { return nil }
            await store(data)
            guard !Task.isCancelled else { return nil }
            return Result(data: data, isProvisional: false)
        }
        guard !Task.isCancelled, let data = await fallback(), !Task.isCancelled else { return nil }
        return Result(data: data, isProvisional: true)
    }
}
