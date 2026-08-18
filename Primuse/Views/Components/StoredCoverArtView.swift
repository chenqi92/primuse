import SwiftUI
import MusicKit
import PrimuseKit
#if os(iOS)
import PhotosUI
#endif
#if os(iOS) || os(macOS)
import UniformTypeIdentifiers
#endif

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
    @State private var uploadedImage: PlatformImage?
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

    private var overrideOwner: LibraryArtworkOwner {
        LibraryArtworkOwner(kind: .playlist, id: playlist.id)
    }

    private var overrideResolution: LibraryArtworkOverrideResolution {
        library.artworkOverrideResolution(for: overrideOwner, eligibleSongs: songs)
    }

    private var selectedArtworkSong: PrimuseKit.Song? {
        guard case .selectedSong(let songID) = overrideResolution else { return nil }
        return songs.first(where: { $0.id == songID })
    }

    private var uploadedContentID: String? {
        guard case .uploaded(let contentID) = overrideResolution else { return nil }
        return contentID
    }

    private var loadIdentity: String {
        [
            plan.signature,
            String(library.playlistCollectionRevision),
            library.songReplacementToken.uuidString,
            String(library.artworkOverrideRevision),
            String(NetworkMonitor.shared.pathGeneration),
            String(reloadRevision),
        ].joined(separator: "#")
    }

    var body: some View {
        ZStack {
            placeholder
            resolvedArtwork
            manualArtwork
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
        .task(id: "\(uploadedContentID ?? "")#\(library.artworkOverrideRevision)#\(reloadRevision)") {
            guard let contentID = uploadedContentID,
                  let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID) else {
                uploadedImage = nil
                return
            }
            uploadedImage = PlatformImage(data: data)
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

    @ViewBuilder
    private var manualArtwork: some View {
        if let uploadedImage, uploadedContentID != nil {
            Image(platformImage: uploadedImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
        } else if let song = selectedArtworkSong {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: size,
                cornerRadius: 0,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                showsPlaceholder: false,
                revisionToken: library.artworkOverrideRevision
            )
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
        if let contentID = uploadedContentID {
            if notification.object as? String == contentID {
                return true
            }
            if let tokens = notification.userInfo?["tokens"] as? [String],
               tokens.contains(contentID) {
                return true
            }
        }
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

/// Album artwork follows the same user override policy as playlists. The
/// existing album resolver stays underneath so a removed song, a missing
/// upload, or an asynchronous source failure always falls back to automatic
/// artwork instead of rendering transparent content.
struct AlbumArtworkView: View {
    let album: PrimuseKit.Album
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 12
    var showsPlaceholder = true

    @Environment(MusicLibrary.self) private var library
    @State private var uploadedImage: PlatformImage?
    @State private var reloadRevision = 0

    private var songs: [PrimuseKit.Song] {
        library.songs(forAlbum: album.id)
    }

    private var owner: LibraryArtworkOwner {
        LibraryArtworkOwner(kind: .album, id: album.id)
    }

    private var resolution: LibraryArtworkOverrideResolution {
        library.artworkOverrideResolution(for: owner, eligibleSongs: songs)
    }

    private var selectedSong: PrimuseKit.Song? {
        guard case .selectedSong(let songID) = resolution else { return nil }
        return songs.first(where: { $0.id == songID })
    }

    private var uploadedContentID: String? {
        guard case .uploaded(let contentID) = resolution else { return nil }
        return contentID
    }

    var body: some View {
        ZStack {
            CachedArtworkView(
                albumID: album.id,
                albumTitle: album.title,
                artistName: album.artistName,
                size: size,
                cornerRadius: cornerRadius,
                showsPlaceholder: showsPlaceholder
            )

            if let uploadedImage, uploadedContentID != nil {
                Image(platformImage: uploadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let song = selectedSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: size,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    showsPlaceholder: false,
                    revisionToken: library.artworkOverrideRevision
                )
            }
        }
        .if(size != nil) { view in
            view.frame(width: size!, height: size!)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(uploadedContentID ?? "")#\(library.artworkOverrideRevision)#\(reloadRevision)") {
            guard let contentID = uploadedContentID,
                  let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID) else {
                uploadedImage = nil
                return
            }
            uploadedImage = PlatformImage(data: data)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard let contentID = uploadedContentID else { return }
            let objectMatches = note.object as? String == contentID
            let tokensMatch = (note.userInfo?["tokens"] as? [String])?.contains(contentID) == true
            guard objectMatches || tokensMatch else { return }
            reloadRevision &+= 1
        }
    }
}

#if os(iOS) || os(macOS)
/// Shared editor used by both album and playlist detail pages. Choices are
/// applied immediately and remain durable even when the underlying album is
/// rebuilt from song metadata.
struct LibraryArtworkEditorSheet: View {
    let owner: LibraryArtworkOwner
    let title: String
    let songs: [PrimuseKit.Song]

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @State private var artworkAvailability: [String: Bool] = [:]
    @State private var isProcessing = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    #else
    @State private var isFileImporterPresented = false
    #endif

    private var resolution: LibraryArtworkOverrideResolution {
        library.artworkOverrideResolution(for: owner, eligibleSongs: songs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if library.setAutomaticArtwork(for: owner) {
                            dismiss()
                        }
                    } label: {
                        artworkActionLabel(
                            titleKey: "artwork_mode_automatic",
                            systemImage: "wand.and.stars",
                            isSelected: resolution == .automatic
                        )
                    }

                    uploadControl
                } footer: {
                    Text("artwork_storage_hint")
                }

                Section("artwork_choose_song") {
                    if songs.isEmpty {
                        Text("artwork_no_songs")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(songs) { song in
                            songChoice(song)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("cancel") { dismiss() }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                #endif
            }
            .disabled(isProcessing)
            .overlay {
                if isProcessing {
                    ProgressView("artwork_processing")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(
                String(localized: "artwork_upload_failed"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            #if os(macOS)
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else {
                        errorMessage = String(localized: "artwork_invalid_image")
                        return
                    }
                    processUpload(data)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
        #if os(iOS)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        errorMessage = String(localized: "artwork_invalid_image")
                        return
                    }
                    processUpload(data)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var uploadControl: some View {
        #if os(iOS)
        let isUploaded: Bool = {
            if case .uploaded = resolution { return true }
            return false
        }()
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            HStack(spacing: 12) {
                Image(systemName: "photo.badge.plus")
                    .frame(width: 28)
                Text("artwork_upload")
                Spacer()
                if isUploaded {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        #else
        Button {
            isFileImporterPresented = true
        } label: {
            artworkActionLabel(
                titleKey: "artwork_upload",
                systemImage: "photo.badge.plus",
                isSelected: {
                    if case .uploaded = resolution { return true }
                    return false
                }()
            )
        }
        #endif
    }

    private func artworkActionLabel(
        titleKey: LocalizedStringKey,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
            Text(titleKey)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func songChoice(_ song: PrimuseKit.Song) -> some View {
        let isAvailable = artworkAvailability[song.id] == true
        let isSelected: Bool = {
            guard case .selectedSong(let songID) = resolution else { return false }
            return songID == song.id
        }()
        return Button {
            if library.setArtwork(for: owner, to: song) {
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 44,
                    cornerRadius: 6,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    onResolutionChange: { available in
                        artworkAvailability[song.id] = available
                    }
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .lineLimit(1)
                    Text(song.artistName ?? String(localized: "unknown_artist"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                } else if !isAvailable {
                    Image(systemName: "photo.slash")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    private func processUpload(_ data: Data) {
        isProcessing = true
        errorMessage = nil
        Task {
            let processed = await Task.detached(priority: .userInitiated) {
                LibraryArtworkImageProcessor.process(data)
            }.value
            guard let processed,
                  let contentID = await MetadataAssetStore.shared.storeCustomArtwork(processed),
                  library.setUploadedArtwork(contentID: contentID, for: owner) else {
                isProcessing = false
                errorMessage = String(localized: "artwork_invalid_image")
                return
            }
            isProcessing = false
            dismiss()
        }
    }
}
#endif

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
