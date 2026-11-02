#if os(iOS)
import AppIntents
import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers

struct PrimuseLibrarySongEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static let defaultQuery = PrimuseLibrarySongQuery()
    let id: String
    let title: String
    let subtitle: String
    let artworkData: Data?

    init(_ song: Song, artistDisplayName: String?, coverData: Data?, showsArtwork: Bool) {
        id = song.id
        title = song.title
        let details = [artistDisplayName, song.albumTitle]
            .compactMap { SiriRadioStationCatalog.safeDisplayName($0) }
            .joined(separator: " — ")
        subtitle = [details.isEmpty ? nil : details,
                    song.duration.isFinite && song.duration > 0 ? song.duration.formattedDuration : nil]
            .compactMap { $0 }.joined(separator: " · ")
        artworkData = showsArtwork ? Self.thumbnail(coverData) : nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.isEmpty ? nil : "\(subtitle)",
                              image: artworkData.map { .init(data: $0, isTemplate: false) }
                                ?? .init(systemName: "music.note"))
    }

    @MainActor
    static func entities(for songs: [Song]) async -> [Self] {
        let inputs = songs.map { ($0, AppServices.shared.musicLibrary.artistDisplayName(for: $0)) }
        let showsArtwork = SpotlightIndexService.showsArtwork
        let worker = Task.detached(priority: .utility) {
            var entities: [Self] = []
            for (song, artist) in inputs {
                guard !Task.isCancelled else { return [] as [Self] }
                let entity = autoreleasepool {
                    let cover = showsArtwork ? MetadataAssetStore.shared.displayCoverData(
                        songID: song.id, reference: song.coverArtFileName
                    ) : nil
                    return Self(song, artistDisplayName: artist, coverData: cover, showsArtwork: showsArtwork)
                }
                entities.append(entity)
            }
            return entities
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
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
