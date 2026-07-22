import SwiftUI
import PrimuseKit

enum LibrarySection: String, CaseIterable, Hashable {
    case playlists, artists, albums, songs

    static let browserOrder: [LibrarySection] = [.songs, .albums, .artists, .playlists]

    var title: LocalizedStringKey {
        switch self {
        case .playlists: return "tab_playlists"
        case .artists: return "tab_artists"
        case .albums: return "tab_albums"
        case .songs: return "tab_songs"
        }
    }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        }
    }

    var color: Color {
        switch self {
        case .playlists: return .red
        case .artists: return .pink
        case .albums: return .purple
        case .songs: return .blue
        }
    }
}

enum LibraryDeepLink: Equatable, Sendable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

enum LibraryPinKind: String, Codable {
    case album, artist, playlist
}

struct LibraryPinReference: Codable, Hashable, Identifiable {
    let kind: LibraryPinKind
    let itemID: String

    var id: String { "\(kind.rawValue):\(itemID)" }
}

enum LibraryPinStorage {
    static let defaultsKey = "primuse.library.quickAccess.v1"
    static let maximumCount = 5

    static func decode(_ rawValue: String) -> [LibraryPinReference] {
        guard let data = rawValue.data(using: .utf8),
              let pins = try? JSONDecoder().decode([LibraryPinReference].self, from: data) else {
            return []
        }
        return Array(pins.prefix(maximumCount))
    }

    static func encode(_ pins: [LibraryPinReference]) -> String {
        guard let data = try? JSONEncoder().encode(Array(pins.prefix(maximumCount))) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct LibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Binding private var deepLink: LibraryDeepLink?
    @State private var navigationPath = NavigationPath()
    @State private var showQuickAccessEditor = false
    @AppStorage(LibraryPinStorage.defaultsKey)
    private var quickAccessRawValue = ""

    private var songs: [Song] { library.visibleSongs }
    private var albums: [Album] { library.visibleAlbums }
    private var artists: [Artist] { library.visibleArtists }
    private var regularPlaylists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }
    private var hasContent: Bool {
        !songs.isEmpty
            || !albums.isEmpty
            || !artists.isEmpty
            || !regularPlaylists.isEmpty
            || !library.smartPlaylists.isEmpty
    }
    private var storedPins: [LibraryPinReference] {
        LibraryPinStorage.decode(quickAccessRawValue)
    }
    private var visiblePins: [LibraryPinReference] {
        storedPins.filter(pinExists)
    }
    private var likedPlaylist: Playlist {
        library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }

    init(deepLink: Binding<LibraryDeepLink?> = .constant(nil)) {
        self._deepLink = deepLink
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if hasContent {
                    libraryHub
                } else {
                    emptyLibraryState
                }
            }
            .navigationTitle("library_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: LibrarySection.self) { section in
                destination(for: section)
                    .navigationTitle(section.title)
                    .toolbarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .onAppear {
                sanitizeStoredPins()
                applyDeepLink(deepLink)
            }
            .onChange(of: deepLink) { _, newValue in
                applyDeepLink(newValue)
            }
            .sheet(isPresented: $showQuickAccessEditor) {
                LibraryQuickAccessEditor(pinsRawValue: $quickAccessRawValue)
            }
        }
    }

    private var libraryHub: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                quickAccessSection
                browseLibrarySection
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("library_quick_access") {
                Button("edit") {
                    showQuickAccessEditor = true
                }
                .font(.subheadline.weight(.medium))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    NavigationLink(value: likedPlaylist) {
                        quickAccessLabel(
                            title: String(localized: "sidebar_liked_songs"),
                            subtitle: countText(
                                library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).count,
                                unitKey: "songs_count"
                            )
                        ) {
                            likedArtwork
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(visiblePins) { pin in
                        pinnedItemCard(pin)
                    }

                    Button {
                        showQuickAccessEditor = true
                    } label: {
                        addQuickAccessLabel
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }

    private var browseLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("library_browse")

            LazyVStack(spacing: 10) {
                ForEach(LibrarySection.browserOrder, id: \.self) { section in
                    NavigationLink(value: section) {
                        libraryCategoryRow(section)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func sectionHeader<Trailing: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(titleKey)
                .font(.title3.weight(.bold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ titleKey: LocalizedStringKey) -> some View {
        sectionHeader(titleKey) {
            EmptyView()
        }
    }

    private var likedArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.pink, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "heart.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 116, height: 116)
        .shadow(color: .pink.opacity(0.18), radius: 8, y: 4)
    }

    private func quickAccessLabel<Artwork: View>(
        title: String,
        subtitle: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            artwork()
                .frame(width: 116, height: 116)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 116, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var addQuickAccessLabel: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 116, height: 116)

            Text("library_add_quick_access")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("\(visiblePins.count)/\(LibraryPinStorage.maximumCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 116, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func pinnedItemCard(_ pin: LibraryPinReference) -> some View {
        switch pin.kind {
        case .album:
            if let album = albums.first(where: { $0.id == pin.itemID }) {
                NavigationLink(value: album) {
                    quickAccessLabel(
                        title: album.title,
                        subtitle: album.artistName ?? String(localized: "unknown_artist")
                    ) {
                        CachedArtworkView(
                            albumID: album.id,
                            albumTitle: album.title,
                            artistName: album.artistName,
                            size: 116,
                            cornerRadius: 16
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        case .artist:
            if let artist = artists.first(where: { $0.id == pin.itemID }) {
                NavigationLink(value: artist) {
                    quickAccessLabel(
                        title: artist.name,
                        subtitle: countText(artist.albumCount, unitKey: "albums_count")
                    ) {
                        CachedArtworkView(
                            artistID: artist.id,
                            artistName: artist.name,
                            size: 116,
                            cornerRadius: 58
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        case .playlist:
            if let playlist = regularPlaylists.first(where: { $0.id == pin.itemID }) {
                NavigationLink(value: playlist) {
                    quickAccessLabel(
                        title: playlist.name,
                        subtitle: countText(
                            library.songs(forPlaylist: playlist.id).count,
                            unitKey: "songs_count"
                        )
                    ) {
                        playlistArtwork(playlist, size: 116, cornerRadius: 16)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func libraryCategoryRow(_ section: LibrarySection) -> some View {
        HStack(spacing: 13) {
            Image(systemName: section.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(categoryCountText(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            categoryPreview(section)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 72)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func categoryPreview(_ section: LibrarySection) -> some View {
        switch section {
        case .songs:
            overlappingPreview(Array(songs.prefix(3))) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .albums:
            overlappingPreview(Array(albums.prefix(3))) { album in
                CachedArtworkView(
                    albumID: album.id,
                    albumTitle: album.title,
                    artistName: album.artistName,
                    size: 36,
                    cornerRadius: 7
                )
            }
        case .artists:
            overlappingPreview(Array(artists.prefix(3))) { artist in
                CachedArtworkView(
                    artistID: artist.id,
                    artistName: artist.name,
                    size: 36,
                    cornerRadius: 18
                )
            }
        case .playlists:
            overlappingPreview(Array(regularPlaylists.prefix(3))) { playlist in
                playlistArtwork(playlist, size: 36, cornerRadius: 7)
            }
        }
    }

    private func overlappingPreview<Item: Identifiable, Content: View>(
        _ items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        HStack(spacing: -10) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
            } else {
                ForEach(items) { item in
                    content(item)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
            }
        }
        .frame(width: 68, alignment: .trailing)
    }

    @ViewBuilder
    private func playlistArtwork(_ playlist: Playlist, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let song = library.songs(forPlaylist: playlist.id).first {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: size,
                cornerRadius: cornerRadius,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
        } else {
            StoredCoverArtView(fileName: playlist.coverArtPath, size: size, cornerRadius: cornerRadius)
        }
    }

    private func categoryCountText(_ section: LibrarySection) -> String {
        switch section {
        case .songs:
            return countText(songs.count, unitKey: "songs_count")
        case .albums:
            return countText(albums.count, unitKey: "albums_count")
        case .artists:
            return countText(artists.count, unitKey: "artists_count")
        case .playlists:
            return countText(
                regularPlaylists.count + library.smartPlaylists.count,
                unitKey: "playlists_count"
            )
        }
    }

    private func countText(_ count: Int, unitKey: String.LocalizationValue) -> String {
        "\(count.formatted()) \(String(localized: unitKey))"
    }

    @ViewBuilder
    private func destination(for section: LibrarySection) -> some View {
        switch section {
        case .songs:
            SongListView()
        case .albums:
            AlbumGridView()
        case .artists:
            ArtistListView(artists: artists)
        case .playlists:
            PlaylistListView()
        }
    }

    private var emptyLibraryState: some View {
        ContentUnavailableView {
            Label("welcome_title", systemImage: "music.note.list")
        } description: {
            Text("welcome_desc")
        } actions: {
            NavigationLink {
                SourcesContentView()
            } label: {
                Text("manage_sources")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func pinExists(_ pin: LibraryPinReference) -> Bool {
        switch pin.kind {
        case .album:
            return albums.contains { $0.id == pin.itemID }
        case .artist:
            return artists.contains { $0.id == pin.itemID }
        case .playlist:
            return regularPlaylists.contains { $0.id == pin.itemID }
        }
    }

    private func sanitizeStoredPins() {
        let sanitized = storedPins.filter(pinExists)
        guard sanitized != storedPins else { return }
        quickAccessRawValue = LibraryPinStorage.encode(sanitized)
    }

    private func applyDeepLink(_ link: LibraryDeepLink?) {
        guard let link else { return }
        var path = NavigationPath()
        switch link {
        case .album(let album):
            path.append(album)
        case .artist(let artist):
            path.append(artist)
        case .playlist(let playlist):
            path.append(playlist)
        }
        navigationPath = path
        deepLink = nil
    }
}

private struct LibraryQuickAccessEditor: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Binding var pinsRawValue: String
    @State private var searchText = ""

    private var pins: [LibraryPinReference] {
        LibraryPinStorage.decode(pinsRawValue)
    }
    private var selectedPins: [LibraryPinReference] {
        pins.filter(pinMatchesSearch)
    }
    private var albums: [Album] {
        let matching = library.visibleAlbums.filter {
            let pin = LibraryPinReference(kind: .album, itemID: $0.id)
            return !pins.contains(pin)
                && (
                    searchText.isEmpty
                        || $0.title.localizedCaseInsensitiveContains(searchText)
                        || ($0.artistName?.localizedCaseInsensitiveContains(searchText) ?? false)
                )
        }
        return matching.sorted {
            return $0.title.localizedCompare($1.title) == .orderedAscending
        }
    }
    private var artists: [Artist] {
        let matching = library.visibleArtists.filter {
            let pin = LibraryPinReference(kind: .artist, itemID: $0.id)
            return !pins.contains(pin)
                && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText))
        }
        return matching.sorted {
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }
    private var playlists: [Playlist] {
        let matching = library.playlists
            .filter { $0.id != MusicLibrary.likedSongsPlaylistID }
            .filter {
                let pin = LibraryPinReference(kind: .playlist, itemID: $0.id)
                return !pins.contains(pin)
                    && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText))
            }
        return matching.sorted {
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty || !selectedPins.isEmpty {
                    Section {
                        if pins.isEmpty {
                            Label("library_quick_access_selected_empty", systemImage: "pin")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selectedPins) { pin in
                                selectedPinRow(pin)
                            }
                        }
                    } header: {
                        HStack {
                            Text("library_quick_access_selected")
                            Spacer()
                            Text("\(pins.count)/\(LibraryPinStorage.maximumCount)")
                                .monospacedDigit()
                        }
                    } footer: {
                        Text("library_quick_access_limit")
                    }
                }

                if !albums.isEmpty {
                    Section("tab_albums") {
                        ForEach(albums) { album in
                            pinButton(
                                LibraryPinReference(kind: .album, itemID: album.id)
                            ) {
                                CachedArtworkView(
                                    albumID: album.id,
                                    albumTitle: album.title,
                                    artistName: album.artistName,
                                    size: 42,
                                    cornerRadius: 7
                                )
                            } title: {
                                Text(album.title)
                            } subtitle: {
                                Text(album.artistName ?? String(localized: "unknown_artist"))
                            }
                        }
                    }
                }

                if !artists.isEmpty {
                    Section("tab_artists") {
                        ForEach(artists) { artist in
                            pinButton(
                                LibraryPinReference(kind: .artist, itemID: artist.id)
                            ) {
                                CachedArtworkView(
                                    artistID: artist.id,
                                    artistName: artist.name,
                                    size: 42,
                                    cornerRadius: 21
                                )
                            } title: {
                                Text(artist.name)
                            } subtitle: {
                                Text("\(artist.albumCount) \(String(localized: "albums_count"))")
                            }
                        }
                    }
                }

                if !playlists.isEmpty {
                    Section("tab_playlists") {
                        ForEach(playlists) { playlist in
                            pinButton(
                                LibraryPinReference(kind: .playlist, itemID: playlist.id)
                            ) {
                                editorPlaylistArtwork(playlist)
                            } title: {
                                Text(playlist.name)
                            } subtitle: {
                                Text(
                                    "\(library.songs(forPlaylist: playlist.id).count) "
                                        + String(localized: "songs_count")
                                )
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text("library_quick_access_search_prompt")
            )
            #else
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("library_quick_access_search_prompt")
            )
            #endif
            .navigationTitle("library_edit_quick_access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedPinRow(_ pin: LibraryPinReference) -> some View {
        switch pin.kind {
        case .album:
            if let album = library.visibleAlbums.first(where: { $0.id == pin.itemID }) {
                pinButton(pin) {
                    CachedArtworkView(
                        albumID: album.id,
                        albumTitle: album.title,
                        artistName: album.artistName,
                        size: 42,
                        cornerRadius: 7
                    )
                } title: {
                    Text(album.title)
                } subtitle: {
                    Text(album.artistName ?? String(localized: "unknown_artist"))
                }
            }
        case .artist:
            if let artist = library.visibleArtists.first(where: { $0.id == pin.itemID }) {
                pinButton(pin) {
                    CachedArtworkView(
                        artistID: artist.id,
                        artistName: artist.name,
                        size: 42,
                        cornerRadius: 21
                    )
                } title: {
                    Text(artist.name)
                } subtitle: {
                    Text("\(artist.albumCount) \(String(localized: "albums_count"))")
                }
            }
        case .playlist:
            if let playlist = library.playlists.first(where: { $0.id == pin.itemID }) {
                pinButton(pin) {
                    editorPlaylistArtwork(playlist)
                } title: {
                    Text(playlist.name)
                } subtitle: {
                    Text(
                        "\(library.songs(forPlaylist: playlist.id).count) "
                            + String(localized: "songs_count")
                    )
                }
            }
        }
    }

    private func pinMatchesSearch(_ pin: LibraryPinReference) -> Bool {
        switch pin.kind {
        case .album:
            guard let album = library.visibleAlbums.first(where: { $0.id == pin.itemID }) else {
                return false
            }
            return searchText.isEmpty
                || album.title.localizedCaseInsensitiveContains(searchText)
                || (album.artistName?.localizedCaseInsensitiveContains(searchText) ?? false)
        case .artist:
            guard let artist = library.visibleArtists.first(where: { $0.id == pin.itemID }) else {
                return false
            }
            return searchText.isEmpty || artist.name.localizedCaseInsensitiveContains(searchText)
        case .playlist:
            guard let playlist = library.playlists.first(where: { $0.id == pin.itemID }) else {
                return false
            }
            return searchText.isEmpty || playlist.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func pinButton<Artwork: View, Title: View, Subtitle: View>(
        _ pin: LibraryPinReference,
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        let isSelected = pins.contains(pin)
        let canSelect = isSelected || pins.count < LibraryPinStorage.maximumCount

        return Button {
            toggle(pin)
        } label: {
            HStack(spacing: 12) {
                artwork()

                VStack(alignment: .leading, spacing: 2) {
                    title()
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    subtitle()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .opacity(canSelect ? 1 : 0.45)
    }

    @ViewBuilder
    private func editorPlaylistArtwork(_ playlist: Playlist) -> some View {
        if let song = library.songs(forPlaylist: playlist.id).first {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 42,
                cornerRadius: 7,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
        } else {
            StoredCoverArtView(fileName: playlist.coverArtPath, size: 42, cornerRadius: 7)
        }
    }

    private func toggle(_ pin: LibraryPinReference) {
        var updated = pins
        if let index = updated.firstIndex(of: pin) {
            updated.remove(at: index)
        } else if updated.count < LibraryPinStorage.maximumCount {
            updated.append(pin)
        }
        pinsRawValue = LibraryPinStorage.encode(updated)
    }
}

#Preview {
    LibraryView()
        .environment(MusicLibrary())
}
