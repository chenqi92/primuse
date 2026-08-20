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

    private var overrideOwner: LibraryArtworkOwner {
        LibraryArtworkOwner(kind: .playlist, id: playlist.id)
    }

    private var loadRevisionIdentity: String {
        [
            playlist.id,
            String(library.playlistCollectionRevision),
            library.songReplacementToken.uuidString,
            String(library.artworkOverrideRevision),
            String(NetworkMonitor.shared.pathGeneration),
            String(reloadRevision),
        ].joined(separator: "#")
    }

    var body: some View {
        let presentation = library.artworkPresentation(for: overrideOwner)
        let uploadedContentID = presentation.uploadedContentID

        ZStack {
            placeholder
            resolvedArtwork
            manualArtwork(presentation)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: loadRevisionIdentity) {
            let identity = loadRevisionIdentity
            let playlistSnapshot = currentPlaylist
            let currentSongs = songs
            let currentPlan = await Task.detached(priority: .userInitiated) {
                PlaylistArtworkResolutionPolicy.makePlan(
                    playlist: playlistSnapshot,
                    songs: currentSongs
                )
            }.value
            guard !Task.isCancelled, loadRevisionIdentity == identity else { return }
            let cacheDiscriminator = [
                String(playlistSnapshot.updatedAt.timeIntervalSinceReferenceDate),
                library.songReplacementToken.uuidString,
                String(reloadRevision),
            ].joined(separator: "#")
            if resolvedPlanSignature != currentPlan.signature {
                resource = nil
                frameworkFallbackResource = nil
            }
            let resolved = await PlaylistArtworkResourceResolver.resolve(
                playlist: playlistSnapshot,
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
                    playlist: playlistSnapshot,
                    plan: fallbackPlan,
                    songs: currentSongs,
                    size: size,
                    sourceManager: sourceManager,
                    cacheDiscriminator: cacheDiscriminator
                )?.value
            } else {
                frameworkFallback = nil
            }
            guard !Task.isCancelled, loadRevisionIdentity == identity else { return }
            resource = resolved?.value
            frameworkFallbackResource = frameworkFallback
            resolvedPlanSignature = currentPlan.signature
        }
        .task(id: "\(uploadedContentID ?? "")#\(library.artworkOverrideRevision)#\(reloadRevision)") {
            guard let contentID = uploadedContentID else {
                uploadedImage = nil
                return
            }
            let data = await Task.detached(priority: .utility) {
                MetadataAssetStore.shared.customArtworkData(contentID: contentID)
            }.value
            guard !Task.isCancelled, let data else {
                uploadedImage = nil
                return
            }
            uploadedImage = PlatformImage(data: data)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard notification(
                note,
                affects: currentPlaylist,
                songs: songs,
                uploadedContentID: uploadedContentID
            ) else { return }
            reloadRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard notification(
                note,
                affects: currentPlaylist,
                songs: songs,
                uploadedContentID: uploadedContentID
            ) else { return }
            reloadRevision &+= 1
        }
    }

    @ViewBuilder
    private func manualArtwork(_ presentation: MusicLibrary.ArtworkPresentation) -> some View {
        if let uploadedImage, presentation.uploadedContentID != nil {
            Image(platformImage: uploadedImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
        } else if let song = presentation.selectedSong {
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
        affects playlist: PrimuseKit.Playlist,
        songs: [PrimuseKit.Song],
        uploadedContentID: String?
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
        let songIDs = Set(songs.map(\.id))
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
        var references = Set(songs.compactMap(\.coverArtFileName))
        if playlist.hasDedicatedCoverArt, let dedicatedReference = playlist.coverArtPath {
            references.insert(dedicatedReference)
        }
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

    private var owner: LibraryArtworkOwner {
        LibraryArtworkOwner(kind: .album, id: album.id)
    }

    var body: some View {
        let presentation = library.artworkPresentation(for: owner)
        let uploadedContentID = presentation.uploadedContentID

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
            } else if let song = presentation.selectedSong {
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
            guard let contentID = uploadedContentID else {
                uploadedImage = nil
                return
            }
            let data = await Task.detached(priority: .utility) {
                MetadataAssetStore.shared.customArtworkData(contentID: contentID)
            }.value
            guard !Task.isCancelled, let data else {
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
    @State private var macDraftChoice: MacArtworkChoice?
    @State private var macPendingUploadData: Data?
    @State private var macUploadedPreview: PlatformImage?
    #endif

    private var resolution: LibraryArtworkOverrideResolution {
        library.artworkOverrideResolution(for: owner, eligibleSongs: songs)
    }

    var body: some View {
        #if os(macOS)
        macEditor
        #else
        iosEditor
        #endif
    }

    #if os(iOS)
    private var iosEditor: some View {
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
        }
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
    }
    #endif

    #if os(macOS)
    private enum MacArtworkChoice: Equatable {
        case automatic
        case selectedSong(String)
        case uploaded(String)
        case pendingUpload
    }

    private var resolvedMacChoice: MacArtworkChoice {
        switch resolution {
        case .automatic:
            return .automatic
        case .selectedSong(let songID):
            return .selectedSong(songID)
        case .uploaded(let contentID):
            return .uploaded(contentID)
        }
    }

    private var macChoice: MacArtworkChoice {
        macDraftChoice ?? resolvedMacChoice
    }

    private var macHasChanges: Bool {
        macChoice != resolvedMacChoice
    }

    private var macEditor: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text("artwork_storage_hint")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("cancel"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    macArtworkPreview
                        .frame(width: 176, height: 176)
                        .background(PMColor.bgDeep, in: .rect(cornerRadius: PMRadius.l))
                        .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)

                    VStack(spacing: 8) {
                        macChoiceButton(
                            titleKey: "artwork_mode_automatic",
                            systemImage: "wand.and.stars",
                            choice: .automatic
                        )

                        Button {
                            isFileImporterPresented = true
                        } label: {
                            macChoiceLabel(
                                titleKey: "artwork_upload",
                                systemImage: "photo.badge.plus",
                                isSelected: {
                                    switch macChoice {
                                    case .uploaded, .pendingUpload: true
                                    default: false
                                    }
                                }()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 176)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("artwork_choose_song")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Spacer()
                        Text(verbatim: songs.count.formatted())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }

                    if songs.isEmpty {
                        ContentUnavailableView(
                            String(localized: "artwork_no_songs"),
                            systemImage: "photo.on.rectangle.angled"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                                alignment: .leading,
                                spacing: 14
                            ) {
                                ForEach(songs) { song in
                                    macSongChoice(song)
                                }
                            }
                            .padding(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("artwork_processing")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                Button("cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("save") { applyMacChoice() }
                    .buttonStyle(.borderedProminent)
                    .tint(PMColor.brand)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!macHasChanges || isProcessing)
            }
            .controlSize(.regular)
            .padding(.horizontal, 24)
            .frame(height: 58)
        }
        .frame(width: 700, height: 540)
        .background(PMColor.bg)
        .disabled(isProcessing)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleMacImport
        )
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
        .onAppear {
            macDraftChoice = resolvedMacChoice
            if case .uploaded(let contentID) = resolvedMacChoice,
               let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID) {
                macUploadedPreview = PlatformImage(data: data)
            }
        }
    }

    private func macChoiceButton(
        titleKey: LocalizedStringKey,
        systemImage: String,
        choice: MacArtworkChoice
    ) -> some View {
        Button {
            macDraftChoice = choice
        } label: {
            macChoiceLabel(
                titleKey: titleKey,
                systemImage: systemImage,
                isSelected: macChoice == choice
            )
        }
        .buttonStyle(.plain)
    }

    private func macChoiceLabel(
        titleKey: LocalizedStringKey,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? PMColor.brand : PMColor.textMuted)
                .frame(width: 16)
            Text(titleKey)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
            Spacer(minLength: 6)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? PMColor.brand : PMColor.textFaint)
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(isSelected ? PMColor.brand.opacity(0.12) : PMColor.bgElev,
                    in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? PMColor.brand.opacity(0.5) : PMColor.cardBorder,
                              lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }

    private var macArtworkPreview: some View {
        Group {
            switch macChoice {
            case .automatic:
                macAutomaticPreview
            case .selectedSong(let songID):
                if let song = songs.first(where: { $0.id == songID }) {
                    macArtwork(for: song, size: 176)
                } else {
                    macPreviewPlaceholder
                }
            case .uploaded(let contentID):
                if let image = macUploadedPreview
                    ?? MetadataAssetStore.shared.customArtworkData(contentID: contentID).flatMap(PlatformImage.init(data:)) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    macPreviewPlaceholder
                }
            case .pendingUpload:
                if let image = macUploadedPreview {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    macPreviewPlaceholder
                }
            }
        }
    }

    @ViewBuilder
    private var macAutomaticPreview: some View {
        switch owner.kind {
        case .album:
            if let album = library.visibleAlbums.first(where: { $0.id == owner.id }) {
                CachedArtworkView(
                    albumID: album.id,
                    albumTitle: album.title,
                    artistName: album.artistName,
                    size: 176,
                    cornerRadius: 0
                )
            } else if let song = songs.first {
                macArtwork(for: song, size: 176)
            } else {
                macPreviewPlaceholder
            }
        case .playlist:
            if resolution == .automatic, let playlist = library.playlist(id: owner.id) {
                PlaylistArtworkView(playlist: playlist, size: 176, cornerRadius: 0)
            } else if let song = songs.first {
                macArtwork(for: song, size: 176)
            } else {
                macPreviewPlaceholder
            }
        }
    }

    private var macPreviewPlaceholder: some View {
        ZStack {
            PMColor.bgDeep
            Image(systemName: "photo")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(PMColor.textFaint)
        }
    }

    private func macSongChoice(_ song: PrimuseKit.Song) -> some View {
        let isSelected: Bool = {
            guard case .selectedSong(let songID) = macChoice else { return false }
            return songID == song.id
        }()
        let isAvailable = artworkAvailability[song.id] == true
        return Button {
            macDraftChoice = .selectedSong(song.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    macArtwork(for: song, size: 86)
                        .frame(width: 86, height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, PMColor.brand)
                            .padding(6)
                    }
                }
                Text(song.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? String(localized: "unknown_artist"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? PMColor.brand.opacity(0.12) : .clear,
                        in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? PMColor.brand.opacity(0.55) : PMColor.cardBorder,
                                  lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
    }

    private func macArtwork(for song: PrimuseKit.Song, size: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: size,
            cornerRadius: 0,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat,
            onResolutionChange: { available in
                artworkAvailability[song.id] = available
            }
        )
    }

    private func handleMacImport(_ result: Result<[URL], Error>) {
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

    private func applyMacChoice() {
        switch macChoice {
        case .automatic:
            if library.setAutomaticArtwork(for: owner) { dismiss() }
        case .selectedSong(let songID):
            guard let song = songs.first(where: { $0.id == songID }) else { return }
            if library.setArtwork(for: owner, to: song) { dismiss() }
        case .uploaded(let contentID):
            if library.setUploadedArtwork(contentID: contentID, for: owner) { dismiss() }
        case .pendingUpload:
            guard let data = macPendingUploadData else { return }
            isProcessing = true
            Task {
                guard let contentID = await MetadataAssetStore.shared.storeCustomArtwork(data),
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
            guard let processed else {
                isProcessing = false
                errorMessage = String(localized: "artwork_invalid_image")
                return
            }
            #if os(macOS)
            macPendingUploadData = processed
            macUploadedPreview = PlatformImage(data: processed)
            macDraftChoice = .pendingUpload
            #else
            guard let contentID = await MetadataAssetStore.shared.storeCustomArtwork(processed),
                  library.setUploadedArtwork(contentID: contentID, for: owner) else {
                isProcessing = false
                errorMessage = String(localized: "artwork_invalid_image")
                return
            }
            #endif
            isProcessing = false
            #if os(iOS)
            dismiss()
            #endif
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
