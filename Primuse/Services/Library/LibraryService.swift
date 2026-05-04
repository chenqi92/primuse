import Foundation
import PrimuseKit

@MainActor
@Observable
final class LibraryService {
    private let database: LibraryDatabase
    private let scanner: LibraryScanner
    let sourceManager: SourceManager

    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []
    private(set) var sources: [MusicSource] = []

    private(set) var isScanning = false
    private(set) var scanProgress: ScanProgress?

    init(database: LibraryDatabase) {
        self.database = database
        self.sourceManager = SourceManager(database: database)
        let metadataService = MetadataService()
        self.scanner = LibraryScanner(database: database, metadataService: metadataService)
    }

    func loadAll() async {
        do {
            songs = try await database.allSongs()
            albums = try await database.allAlbums()
            artists = try await database.allArtists()
            playlists = try await database.allPlaylists()
            sources = try await database.allSources()
        } catch {
            print("Failed to load library: \(error)")
        }
    }

    func search(query: String) async -> [Song] {
        (try? await database.searchSongs(query: query)) ?? []
    }

    // MARK: - Source Management

    func addSource(_ source: MusicSource, password: String?) async throws {
        if let password {
            KeychainService.setPassword(password, for: source.id)
        }
        try await database.saveSource(source)
        sources = try await database.allSources()
    }

    func removeSource(id: String) async throws {
        try await database.deleteSongs(forSource: id)
        try await database.deleteSource(id: id)
        KeychainService.deletePassword(for: id)
        // 顺手清掉这个源的整个音频缓存子目录, 不然 caches/primuse_audio_cache/<sourceID>/
        // 里几 GB 文件 + .partial 永远没人删, 用户在「存储管理」看到的缓存
        // 大小会一直挂着已删源的存量。
        sourceManager.purgeAudioCache(forSourceID: id)
        sources = try await database.allSources()
        await loadAll()
    }

    // MARK: - Scanning

    func scanSource(_ source: MusicSource) async {
        isScanning = true
        let connector = sourceManager.connector(for: source)

        do {
            let progressStream = await scanner.scan(source: source, connector: connector)
            for try await progress in progressStream {
                scanProgress = progress
            }

            await loadAll()
        } catch {
            print("Scan failed: \(error)")
        }

        isScanning = false
        scanProgress = nil
    }

    func scanAllSources() async {
        for source in sources where source.isEnabled {
            await scanSource(source)
        }
    }

    // MARK: - Playlists

    func createPlaylist(name: String) async throws {
        let playlist = Playlist(name: name)
        try await database.savePlaylist(playlist)
        playlists = try await database.allPlaylists()
    }

    func deletePlaylist(id: String) async throws {
        try await database.deletePlaylist(id: id)
        playlists = try await database.allPlaylists()
    }

    func addToPlaylist(playlistID: String, songID: String) async throws {
        try await database.addSongToPlaylist(playlistID: playlistID, songID: songID)
    }

    // MARK: - Stats

    var songCount: Int { songs.count }
    var albumCount: Int { albums.count }
    var artistCount: Int { artists.count }
}
