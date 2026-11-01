#if os(iOS)
import AppIntents
import Foundation
import PrimuseKit

struct PrimuseLibrarySongEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static let defaultQuery = PrimuseLibrarySongQuery()
    let id: String
    let title: String
    let subtitle: String

    @MainActor
    init(_ song: Song) {
        id = song.id
        title = song.title
        subtitle = [AppServices.shared.musicLibrary.artistDisplayName(for: song), song.albumTitle]
            .compactMap { SiriRadioStationCatalog.safeDisplayName($0) }
            .joined(separator: " — ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "music.note"))
    }
}

struct PrimuseLibrarySongQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PrimuseLibrarySongEntity] {
        let library = AppServices.shared.musicLibrary
        guard await library.whenReady(timeout: .seconds(8)) else { return [] }
        return identifiers.compactMap { library.visibleSong(id: $0) }
            .filter { $0.isPlayable && SiriRadioStationCatalog.safeDisplayName($0.title) != nil }
            .map(PrimuseLibrarySongEntity.init)
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
        return (match?.candidates ?? []).filter {
            SiriRadioStationCatalog.safeDisplayName($0.title) != nil
        }.map(PrimuseLibrarySongEntity.init)
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
