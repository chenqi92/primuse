#if os(tvOS)
import SwiftUI
import PrimuseKit

struct TVArtistArtworkView: View {
    @Environment(TVStore.self) private var store
    let artist: TVArtist
    let size: CGFloat
    @State private var image: UIImage?
    @State private var cacheRevision = 0

    /// 只随这个艺人自己的封面字段失效, 扫描入库时别的艺人变化不牵动这一格。
    private var reference: String? { store.library.scopedVisibleArtist(id: artist.id)?.thumbnailPath }
    private var resolution: LibraryArtworkOverrideResolution {
        store.library.artworkPresentation(for: .init(kind: .artist, id: artist.id)).resolution
    }
    private var identity: String {
        "\(artist.id)#\(reference ?? "")#\(resolution)#\(store.library.artworkOverrideRevision)#\(store.recommendationRevision)#\(cacheRevision)"
    }

    var body: some View {
        ZStack {
            TVCoverArt(tint: artist.tint, tint2: artist.tint2, glyph: artist.glyph, size: size, radius: size / 2)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .task(id: identity) {
            let requestIdentity = identity
            image = nil
            let data = await artworkData()
            guard !Task.isCancelled, identity == requestIdentity, let data else { return }
            let decoded = await Task.detached(priority: .utility) { UIImage(data: data) }.value
            guard !Task.isCancelled, identity == requestIdentity else { return }
            image = decoded
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            if note.userInfo?["all"] as? Bool == true || note.userInfo?["artistID"] as? String == artist.id {
                cacheRevision &+= 1
            } else if case .uploaded(let contentID) = resolution,
                      (note.userInfo?["tokens"] as? [String])?.contains(contentID) == true {
                cacheRevision &+= 1
            } else if case .selectedSong(let songID) = resolution, note.object as? String == songID {
                cacheRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { _ in
            cacheRevision &+= 1
        }
    }

    private func artworkData() async -> Data? {
        switch resolution {
        case .uploaded(let contentID):
            if let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID) { return data }
        case .selectedSong(let songID):
            if let song = store.library.song(id: songID),
               let data = await store.songArtworkData(
                songID: song.id, coverRef: song.coverArtFileName
               ) { return data }
        case .automatic: break
        }

        if let reference, !reference.isEmpty {
            let cacheID = artist.id + "\u{1F}" + reference
            let owned = SourceOwnedArtworkReference.resolve(reference)
            let source = owned.flatMap { store.source(id: $0.sourceID) }
            if owned != nil, source?.isEnabled != true || source?.isDeleted == true { return nil }
            if let data = await MetadataAssetStore.shared.cachedArtistImage(forArtistID: cacheID) { return data }
            let credential = source.flatMap { TVCredentialStore.credential(for: $0, bundle: store.credentialBundle) }
            if let source, source.type == .fnMusic,
               let client = store.fnMusicClient(for: source.id),
               let data = try? await client.coverData(reference: owned?.reference ?? reference, size: 480, maximumBytes: 8 * 1024 * 1024),
               !Task.isCancelled, store.source(id: source.id) == source {
                _ = await MetadataAssetStore.shared.storeArtistImage(data, forArtistID: cacheID)
                return data
            }
            if let data = await TVArtistArtworkReader.read(reference: owned?.reference ?? reference, source: source, credential: credential),
               !Task.isCancelled,
               source.map({ store.source(id: $0.id) == $0 }) ?? true {
                _ = await MetadataAssetStore.shared.storeArtistImage(data, forArtistID: cacheID)
                return data
            }
        }
        return await MetadataAssetStore.shared.cachedArtistImage(forArtistID: artist.id)
    }
}

enum TVArtistArtworkReader {
    private static let maximumBytes = 8 * 1024 * 1024

    static func read(reference: String, source: MusicSource?, credential: SourceCredential?) async -> Data? {
        if let source, TVSourceAssetReader.supports(source.type) {
            return await TVSourceAssetReader.shared.artworkData(
                reference: reference, source: source, credential: credential, maximumBytes: maximumBytes
            )
        }
        do {
            try Task.checkCancellation()
            let data: Data
            if let source, let reader = TVPlaybackCoordinator.makeDirectReader(source: source, filePath: reference, credential: credential) {
                do {
                    let count = try await reader.contentLength()
                    guard count > 0, count <= Int64(maximumBytes) else { await reader.close(); return nil }
                    data = try await reader.read(offset: 0, length: count)
                    await reader.close()
                } catch {
                    await reader.close()
                    throw error
                }
            } else {
                let request: URLRequest
                if let source {
                    guard [.webdav, .oneDrive, .dropbox].contains(source.type) else { return nil }
                    let file = Song(id: "artist-artwork", title: "", fileFormat: .mp3, filePath: reference, sourceID: source.id)
                    let resolved = try await StreamResolverRegistry.shared.resolve(for: file, source: source, credential: credential)
                    var value = URLRequest(url: resolved.url)
                    for (key, header) in resolved.headers { value.setValue(header, forHTTPHeaderField: key) }
                    request = value
                } else {
                    guard let url = URL(string: reference), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                    request = URLRequest(url: url)
                }
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 12
                config.timeoutIntervalForResource = 20
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                let response: URLResponse
                (data, response) = try await StreamResolverHTTPTransport.data(for: request, session: session, maximumBytes: maximumBytes)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            }
            try Task.checkCancellation()
            return await Task.detached(priority: .utility) { LibraryArtworkImageProcessor.process(data) }.value
        } catch { return nil }
    }
}
#endif
