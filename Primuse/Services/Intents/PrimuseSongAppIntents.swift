#if os(iOS)
import AppIntents
import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers

@MainActor
final class SiriSongSuggestionCache {
    struct Inputs: Equatable, Sendable {
        let libraryRevision: UInt64
        let replacementToken: UUID
        let visibleRevision: Int
        let priorityIDs: [String]
        let limit: Int
    }

    typealias Select = @Sendable ([Song], [String], Int) async -> [Song]
    private let select: Select
    private var cached: (inputs: Inputs, songs: [Song])?
    private var pending: (inputs: Inputs, token: UUID, task: Task<[Song], Never>)?

    init(select: @escaping Select = { SiriSongCatalog.shortcuts(from: $0, priorityIDs: $1, limit: $2) }) {
        self.select = select
    }

    func songs(for inputs: Inputs, from songs: [Song]) async -> [Song]? {
        guard !Task.isCancelled else { return nil }
        if let cached, cached.inputs == inputs { return cached.songs }
        if pending?.inputs != inputs {
            pending?.task.cancel()
            cached = nil
            let select = select
            pending = (inputs, UUID(), Task.detached(priority: .utility) {
                await select(songs, inputs.priorityIDs, inputs.limit)
            })
        }
        guard let request = pending else { return nil }
        // One cancelled system query must not cancel work shared by other callers.
        let selected = await request.task.value
        if pending?.token == request.token {
            cached = (inputs, selected)
            pending = nil
            plog("Siri song shortcuts: selected=\(selected.count) budget=\(inputs.limit)")
        }
        guard !Task.isCancelled, cached?.inputs == inputs else { return nil }
        return cached?.songs
    }
}

actor PrimuseSongEntityCache {
    struct Input: Sendable {
        let song: Song
        let artist: String?
    }

    private struct Key: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let duration: UInt64
        let coverReference: String?
        let coverIdentity: String?
        let showsArtwork: Bool

        func hasSameArtwork(as other: Self) -> Bool {
            showsArtwork == other.showsArtwork && coverReference == other.coverReference
                && coverIdentity == other.coverIdentity
        }
    }

    private struct Entry {
        let key: Key
        let entity: PrimuseLibrarySongEntity
        var lastUsed: UInt64
    }

    static let shared = PrimuseSongEntityCache()
    private let capacity: Int
    private let coverIdentity: @Sendable (Song) -> String?
    private let coverData: @Sendable (Song) -> Data?
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 1_024,
         coverIdentity: @escaping @Sendable (Song) -> String? = {
             MetadataAssetStore.shared.readableDisplayCoverIdentity(songID: $0.id, reference: $0.coverArtFileName)
         },
         coverData: @escaping @Sendable (Song) -> Data? = {
             MetadataAssetStore.shared.displayCoverData(songID: $0.id, reference: $0.coverArtFileName)
         }) {
        self.capacity = max(1, capacity)
        self.coverIdentity = coverIdentity
        self.coverData = coverData
    }

    // No suspension between lookup and insertion: simultaneous system queries
    // reuse each thumbnail, including a cached absence of artwork.
    func entities(for inputs: [Input], showsArtwork: Bool) -> [PrimuseLibrarySongEntity] {
        var result: [PrimuseLibrarySongEntity] = []
        for input in inputs {
            guard !Task.isCancelled else { return [] }
            let entity = autoreleasepool {
                let song = input.song
                let key = Key(title: song.title, artist: input.artist, album: song.albumTitle,
                              duration: song.duration.bitPattern, coverReference: song.coverArtFileName,
                              coverIdentity: showsArtwork ? coverIdentity(song) : nil, showsArtwork: showsArtwork)
                clock &+= 1
                if var entry = entries[song.id], entry.key == key {
                    entry.lastUsed = clock
                    entries[song.id] = entry
                    return entry.entity
                }
                let entity: PrimuseLibrarySongEntity
                if let entry = entries[song.id], entry.key.hasSameArtwork(as: key) {
                    entity = PrimuseLibrarySongEntity(song, artistDisplayName: input.artist,
                                                     artworkData: entry.entity.artworkData)
                } else {
                    entity = PrimuseLibrarySongEntity(song, artistDisplayName: input.artist,
                        coverData: showsArtwork ? coverData(song) : nil, showsArtwork: showsArtwork)
                }
                entries[song.id] = Entry(key: key, entity: entity, lastUsed: clock)
                if entries.count > capacity,
                   let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                    entries.removeValue(forKey: oldest)
                }
                return entity
            }
            result.append(entity)
        }
        return result
    }
}

struct PrimuseLibrarySongEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static let defaultQuery = PrimuseLibrarySongQuery()
    let id: String
    let title: String
    let subtitle: String
    let artworkData: Data?

    init(_ song: Song, artistDisplayName: String?, coverData: Data?, showsArtwork: Bool) {
        self.init(song, artistDisplayName: artistDisplayName,
                  artworkData: showsArtwork ? Self.thumbnail(coverData) : nil)
    }

    fileprivate init(_ song: Song, artistDisplayName: String?, artworkData: Data?) {
        id = song.id
        title = song.title
        let details = [artistDisplayName, song.albumTitle]
            .compactMap { SiriRadioStationCatalog.safeDisplayName($0) }
            .joined(separator: " — ")
        subtitle = [details.isEmpty ? nil : details,
                    song.duration.isFinite && song.duration > 0 ? song.duration.formattedDuration : nil]
            .compactMap { $0 }.joined(separator: " · ")
        self.artworkData = artworkData
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.isEmpty ? nil : "\(subtitle)",
                              image: artworkData.map { .init(data: $0, isTemplate: false) }
                                ?? .init(systemName: "music.note"))
    }

    @MainActor
    static func entities(for songs: [Song]) async -> [Self] {
        let inputs = songs.map { PrimuseSongEntityCache.Input(
            song: $0, artist: AppServices.shared.musicLibrary.artistDisplayName(for: $0)
        ) }
        let showsArtwork = SpotlightIndexService.showsArtwork
        return await PrimuseSongEntityCache.shared.entities(for: inputs, showsArtwork: showsArtwork)
    }

    private static func thumbnail(_ data: Data?) -> Data? {
        guard let data, data.count <= 32 * 1024 * 1024,
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(data),
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

struct PrimuseLibrarySongQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PrimuseLibrarySongEntity] {
        let library = AppServices.shared.musicLibrary
        guard await library.whenReady(timeout: .seconds(8)) else { return [] }
        let songs = identifiers.compactMap { library.visibleSong(id: $0) }
            .filter { $0.isPlayable && SiriRadioStationCatalog.safeDisplayName($0.title) != nil }
        return await PrimuseLibrarySongEntity.entities(for: songs)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PrimuseLibrarySongEntity] {
        let library = AppServices.shared.musicLibrary
        guard await library.whenReady(timeout: .seconds(8)) else { return [] }
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let match = SiriMediaSearchResolver.resolvePreferringMusic(
            query: SiriMediaSearchQuery(kind: .song, mediaName: query),
            musicSongs: library.musicSongs,
            spokenWordSongs: library.spokenWordSongs
        )
        let songs = (match?.candidates ?? []).filter {
            SiriRadioStationCatalog.safeDisplayName($0.title) != nil
        }
        return await PrimuseLibrarySongEntity.entities(for: songs)
    }

    @MainActor
    func suggestedEntities() async throws -> [PrimuseLibrarySongEntity] {
        let services = AppServices.shared
        let songs = await services.siriSongShortcutSuggestions()
        let entities = try await entities(for: songs.map(\.id))
        plog("Siri song shortcut suggestions: count=\(entities.count)")
        return entities
    }
}

struct PrimusePlayLibrarySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Song", requestValueDialog: IntentDialog("Which song? Tell Siri the song title."))
    var song: PrimuseLibrarySongEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$song)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await SystemActivityRouter.shared.openSong(id: song.id, route: "AppShortcut") else {
            throw UnavailableSong()
        }
        return .result()
    }

    private struct UnavailableSong: LocalizedError {
        var errorDescription: String? { String(localized: "No matching song in your library.") }
    }
}
#endif
