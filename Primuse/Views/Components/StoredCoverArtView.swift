import SwiftUI
import MusicKit
import PrimuseKit

enum PlaylistArtworkResource {
    case image(PlatformImage)
    case musicKit(MusicKit.Artwork)
}

/// App-layer half of the shared playlist artwork resolver. PrimuseKit owns the
/// deterministic ordering; this adapter proves that each candidate can really
/// be displayed by the same cache/source/MusicKit chain used for song covers.
@MainActor
enum PlaylistArtworkResourceResolver {
    static func resolve(
        playlist: PrimuseKit.Playlist,
        plan: PlaylistArtworkResolutionPlan,
        songs: [PrimuseKit.Song],
        size: CGFloat,
        sourceManager: SourceManager,
        allowsMusicKitArtwork: Bool = true,
        cacheDiscriminator: String = "",
        appleMusicLibrary: AppleMusicLibraryService = AppServices.shared.appleMusicLibrary
    ) async -> PlaylistArtworkResolution<PlaylistArtworkResource>? {
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dedicatedSourceID = MirrorPlaylistSuppressionPolicy
            .key(forPlaylistID: playlist.id)?
            .sourceID

        return await PlaylistArtworkResolver.resolve(plan: plan) { candidate in
            switch candidate.kind {
            case .dedicated:
                if allowsMusicKitArtwork,
                   dedicatedSourceID == AppleMusicLibraryIdentity.sourceID,
                   let artwork = appleMusicLibrary.cachedMusicKitPlaylistArtwork(
                    playlistID: playlist.id
                   ) {
                    return .musicKit(artwork)
                }
                return await CachedArtworkView.resolveImage(
                    coverRef: candidate.artworkReference,
                    songID: nil,
                    size: size,
                    sourceID: dedicatedSourceID,
                    filePath: nil,
                    fileFormat: nil,
                    sourceManager: sourceManager,
                    cacheDiscriminator: cacheDiscriminator
                ).map(PlaylistArtworkResource.image)

            case .song:
                guard let songID = candidate.songID,
                      let song = songsByID[songID] else { return nil }
                if allowsMusicKitArtwork,
                   song.sourceID == AppleMusicLibraryIdentity.sourceID,
                   !song.filePath.isEmpty,
                   let artwork = await appleMusicLibrary.musicKitSong(amID: song.filePath)?.artwork {
                    return .musicKit(artwork)
                }
                return await CachedArtworkView.resolveImage(
                    coverRef: candidate.artworkReference,
                    songID: song.id,
                    size: size,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    sourceManager: sourceManager,
                    cacheDiscriminator: cacheDiscriminator
                ).map(PlaylistArtworkResource.image)
            }
        }
    }
}

/// The single playlist artwork surface for iPhone, iPad, and macOS. It keeps a
/// non-transparent placeholder underneath the async result and reruns the full
/// fallback chain when membership, source artwork, the metadata cache, or the
/// active network route changes.
struct PlaylistArtworkView: View {
    let playlist: PrimuseKit.Playlist
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8
    var placeholderIcon: String = "music.note.list"

    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @State private var resource: PlaylistArtworkResource?
    @State private var frameworkFallbackResource: PlaylistArtworkResource?
    @State private var resolvedPlanSignature: String?
    @State private var reloadRevision = 0

    private var currentPlaylist: PrimuseKit.Playlist {
        library.playlist(id: playlist.id) ?? playlist
    }

    private var songs: [PrimuseKit.Song] {
        library.songs(forPlaylist: playlist.id)
    }

    private var plan: PlaylistArtworkResolutionPlan {
        PlaylistArtworkResolutionPolicy.makePlan(
            playlist: currentPlaylist,
            songs: songs
        )
    }

    private var loadIdentity: String {
        [
            plan.signature,
            String(library.playlistCollectionRevision),
            library.songReplacementToken.uuidString,
            String(NetworkMonitor.shared.pathGeneration),
            String(reloadRevision),
        ].joined(separator: "#")
    }

    var body: some View {
        ZStack {
            placeholder
            resolvedArtwork
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: loadIdentity) {
            let identity = loadIdentity
            let currentPlan = plan
            let currentSongs = songs
            let cacheDiscriminator = [
                String(currentPlaylist.updatedAt.timeIntervalSinceReferenceDate),
                library.songReplacementToken.uuidString,
                String(reloadRevision),
            ].joined(separator: "#")
            if resolvedPlanSignature != currentPlan.signature {
                resource = nil
                frameworkFallbackResource = nil
            }
            let resolved = await PlaylistArtworkResourceResolver.resolve(
                playlist: currentPlaylist,
                plan: currentPlan,
                songs: currentSongs,
                size: size,
                sourceManager: sourceManager,
                cacheDiscriminator: cacheDiscriminator
            )
            // ArtworkImage has no public load/failure callback. Keep the next
            // actually resolvable candidate underneath it so a failed or
            // temporarily transparent MusicKit render never becomes a blank.
            let frameworkFallback: PlaylistArtworkResource?
            if let resolved,
               case .musicKit = resolved.value,
               let index = currentPlan.candidates.firstIndex(of: resolved.candidate),
               currentPlan.candidates.indices.contains(index + 1) {
                let fallbackPlan = PlaylistArtworkResolutionPlan(
                    signature: "\(currentPlan.signature)#framework-fallback",
                    candidates: Array(currentPlan.candidates[(index + 1)...])
                )
                frameworkFallback = await PlaylistArtworkResourceResolver.resolve(
                    playlist: currentPlaylist,
                    plan: fallbackPlan,
                    songs: currentSongs,
                    size: size,
                    sourceManager: sourceManager,
                    cacheDiscriminator: cacheDiscriminator
                )?.value
            } else {
                frameworkFallback = nil
            }
            guard !Task.isCancelled, loadIdentity == identity else { return }
            resource = resolved?.value
            frameworkFallbackResource = frameworkFallback
            resolvedPlanSignature = currentPlan.signature
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard notification(note, affects: plan) else { return }
            reloadRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard notification(note, affects: plan) else { return }
            reloadRevision &+= 1
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.32)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: placeholderIcon)
                .font(.system(size: max(size * 0.25, 10), weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resolvedArtwork: some View {
        ZStack {
            if let frameworkFallbackResource {
                artwork(frameworkFallbackResource)
            }
            if let resource {
                artwork(resource)
            }
        }
    }

    @ViewBuilder
    private func artwork(_ resource: PlaylistArtworkResource) -> some View {
        switch resource {
        case .image(let image):
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
        case .musicKit(let artwork):
            ArtworkImage(artwork, width: size, height: size)
                .frame(width: size, height: size)
                .clipped()
        }
    }

    private func notification(
        _ notification: Notification,
        affects plan: PlaylistArtworkResolutionPlan
    ) -> Bool {
        let songIDs = Set(plan.candidates.compactMap(\.songID))
        if let songID = notification.object as? String, songIDs.contains(songID) {
            return true
        }
        if let songID = notification.userInfo?["songID"] as? String,
           songIDs.contains(songID) {
            return true
        }
        if let changedSongIDs = notification.userInfo?["songIDs"] as? [String],
           changedSongIDs.contains(where: songIDs.contains) {
            return true
        }
        let references = Set(plan.candidates.compactMap(\.artworkReference))
        if let tokens = notification.userInfo?["tokens"] as? [String],
           tokens.contains(where: references.contains) {
            return true
        }
        return false
    }
}

struct StoredCoverArtView: View {
    let fileName: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8

    @State private var data: Data?

    var body: some View {
        CoverArtView(data: data, size: size, cornerRadius: cornerRadius)
            .task(id: fileName) {
                data = await loadData(for: fileName)
            }
    }
}

struct StoredArtworkView: View {
    let fileName: String?
    var cornerRadius: CGFloat = 16

    @State private var data: Data?

    var body: some View {
        ArtworkView(data: data, cornerRadius: cornerRadius)
            .task(id: fileName) {
                data = await loadData(for: fileName)
            }
    }
}

private func loadData(for fileName: String?) async -> Data? {
    guard let fileName, fileName.isEmpty == false else {
        return nil
    }

    if let remoteURL = URL(string: fileName), remoteURL.scheme != nil {
        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    return await MetadataAssetStore.shared.coverData(named: fileName)
}
