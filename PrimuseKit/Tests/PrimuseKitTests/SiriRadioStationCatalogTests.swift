import Foundation
import Testing
@testable import PrimuseKit

@Suite("Siri radio station catalog")
struct SiriRadioStationCatalogTests {
    @Test("Catalog contains only playable stations from enabled sources")
    func filtersUnavailableStations() {
        let local = RadioStation(name: "Local Jazz", streamURL: "https://radio.example/jazz")
        let enabled = serverStation(sourceID: "enabled", serverID: "news", name: "News")
        let disabled = serverStation(sourceID: "disabled", serverID: "talk", name: "Talk")
        var deleted = RadioStation(name: "Deleted", streamURL: "https://radio.example/deleted")
        deleted.isDeleted = true
        let invalid = RadioStation(name: "Invalid", streamURL: "file:///private/radio")

        let result = SiriRadioStationCatalog.availableStations(
            from: [disabled, deleted, invalid, enabled, local],
            enabledSourceIDs: ["enabled"]
        )

        #expect(Set(result.map(\.id)) == [local.id, enabled.id])
    }

    @Test("Catalog aliases use display names and never stream addresses")
    func safeAliases() throws {
        let station = serverStation(
            sourceID: "source",
            serverID: "jazz",
            name: "City Jazz Radio (HD)",
            sourceName: "Living Room NAS"
        )

        let item = try #require(SiriRadioStationCatalog.namedItems(
            from: [station],
            enabledSourceIDs: ["source"]
        ).first)

        #expect(item.aliases.contains("City Jazz Radio"))
        #expect(item.aliases.contains("Living Room NAS City Jazz Radio (HD)"))
        #expect(!item.aliases.joined().contains("https://"))
        #expect(!item.aliases.joined().contains("token"))
    }

    @Test("Playback availability distinguishes success and source failures")
    func playbackAvailability() {
        let local = RadioStation(name: "Local", streamURL: "https://radio.example/live")
        let remote = serverStation(sourceID: "source", serverID: "remote", name: "Remote")
        let invalid = RadioStation(name: "Invalid", streamURL: "file:///private/radio")

        #expect(SiriRadioStationCatalog.playbackAvailability(
            for: local,
            activeSourceIDs: [],
            enabledSourceIDs: []
        ) == .available)
        #expect(SiriRadioStationCatalog.playbackAvailability(
            for: remote,
            activeSourceIDs: ["source"],
            enabledSourceIDs: ["source"]
        ) == .available)
        #expect(SiriRadioStationCatalog.playbackAvailability(
            for: remote,
            activeSourceIDs: ["source"],
            enabledSourceIDs: []
        ) == .sourceDisabled)
        #expect(SiriRadioStationCatalog.playbackAvailability(
            for: remote,
            activeSourceIDs: [],
            enabledSourceIDs: []
        ) == .unavailable)
        #expect(SiriRadioStationCatalog.playbackAvailability(
            for: invalid,
            activeSourceIDs: [],
            enabledSourceIDs: []
        ) == .unavailable)
        #expect(SiriRadioStationCatalog.playbackAvailability(
            for: nil,
            activeSourceIDs: [],
            enabledSourceIDs: []
        ) == .notFound)
    }

    @Test("Credential-shaped station labels never leave the radio catalog")
    func filtersSensitiveDisplayNames() {
        let station = RadioStation(
            name: "https://radio.example/live?token=private",
            streamURL: "https://radio.example/live"
        )

        #expect(SiriRadioStationCatalog.availableStations(
            from: [station],
            enabledSourceIDs: []
        ).isEmpty)
        #expect(SiriRadioStationCatalog.safeDisplayName("Jazz & Blues") == "Jazz & Blues")
        #expect(SiriRadioStationCatalog.safeDisplayName("News token=private") == nil)
        #expect(SiriRadioStationCatalog.safeDisplayName("News Bearer private-token") == nil)
    }

    @Test("Credential-shaped station identifiers never leave the radio catalog")
    func filtersSensitiveIdentifiers() {
        let station = RadioStation(
            id: "https://radio.example/live?token=private",
            name: "Private",
            streamURL: "https://radio.example/live"
        )

        #expect(SiriRadioStationCatalog.availableStations(
            from: [station],
            enabledSourceIDs: []
        ).isEmpty)
        #expect(SiriRadioStationCatalog.isSafeIdentifier("station-123"))
        #expect(!SiriRadioStationCatalog.isSafeIdentifier("station?access_token=private"))
    }

    @Test("Exact aliases resolve without confirmation")
    func aliasResolutionIsConfident() throws {
        let item = SiriNamedMediaItem(
            id: "jazz",
            name: "City Jazz Radio",
            aliases: ["City Jazz"]
        )

        let result = try #require(SiriNamedMediaResolver.resolve(
            query: "City Jazz",
            namespace: "radio",
            items: [item]
        ))

        #expect(result.selected.id == "jazz")
        #expect(!result.needsDisambiguation)
        #expect(!result.requiresConfirmation)
    }

    @Test("Duplicate station names require disambiguation")
    func duplicateNamesRequireDisambiguation() throws {
        let result = try #require(SiriNamedMediaResolver.resolve(
            query: "News Radio",
            namespace: "radio",
            items: [
                SiriNamedMediaItem(id: "a", name: "News Radio"),
                SiriNamedMediaItem(id: "b", name: "News Radio"),
            ]
        ))

        #expect(result.needsDisambiguation)
        #expect(result.candidates.map(\.id) == ["a", "b"])
    }

    @Test("A contained name requires confirmation instead of autoplay")
    func containedNameRequiresConfirmation() throws {
        let result = try #require(SiriNamedMediaResolver.resolve(
            query: "Classical",
            namespace: "radio",
            items: [
                SiriNamedMediaItem(id: "one", name: "Evening Classical Concerts"),
            ]
        ))

        #expect(result.selected.id == "one")
        #expect(!result.needsDisambiguation)
        #expect(result.requiresConfirmation)
    }

    @Test("A bounded spelling error is deterministic and requires confirmation")
    func fuzzyMatchRequiresConfirmation() throws {
        let result = try #require(SiriNamedMediaResolver.resolve(
            query: "Clasic FM",
            namespace: "radio",
            items: [
                SiriNamedMediaItem(id: "jazz", name: "Jazz FM"),
                SiriNamedMediaItem(id: "classic", name: "Classic FM"),
            ]
        ))

        #expect(result.selected.id == "classic")
        #expect(result.requiresConfirmation)
    }

    @Test("A selected station identifier is authoritative")
    func selectedIdentifierBypassesTextGuessing() throws {
        let result = try #require(SiriNamedMediaResolver.resolve(
            query: "News",
            selectedItemIDs: ["radio:second"],
            namespace: "radio",
            items: [
                SiriNamedMediaItem(id: "first", name: "News"),
                SiriNamedMediaItem(id: "second", name: "News"),
            ]
        ))

        #expect(result.selected.id == "second")
        #expect(!result.needsDisambiguation)
        #expect(!result.requiresConfirmation)
    }

    @Test("No station match returns no result")
    func noMatch() {
        #expect(SiriNamedMediaResolver.resolve(
            query: "Ambient",
            namespace: "radio",
            items: [SiriNamedMediaItem(id: "news", name: "Daily News")]
        ) == nil)
    }

    @Test("App Shortcut stations put recently played ones first and stay within the budget")
    func appShortcutStationOrder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var first = RadioStation(name: "A First", streamURL: "https://radio.example/a")
        first.sortOrder = 0
        var second = RadioStation(name: "B Second", streamURL: "https://radio.example/b")
        second.sortOrder = 1_024
        var older = RadioStation(name: "C Older", streamURL: "https://radio.example/c")
        older.sortOrder = 2_048
        older.lastPlayedAt = now.addingTimeInterval(-3_600)
        var recent = RadioStation(name: "D Recent", streamURL: "https://radio.example/d")
        recent.sortOrder = 3_072
        recent.lastPlayedAt = now
        let disabled = serverStation(sourceID: "disabled", serverID: "x", name: "Disabled")

        let ordered = SiriRadioStationCatalog.appShortcutStations(
            from: [first, second, older, recent, disabled],
            enabledSourceIDs: []
        )
        #expect(ordered.map(\.name) == ["D Recent", "C Older", "A First", "B Second"])

        let capped = SiriRadioStationCatalog.appShortcutStations(
            from: [first, second, older, recent],
            enabledSourceIDs: [],
            limit: 3
        )
        #expect(capped.map(\.name) == ["D Recent", "C Older", "A First"])
    }

    @Test("A request naming no station plays the one last listened to")
    func defaultStation() {
        var first = RadioStation(name: "A First", streamURL: "https://radio.example/a")
        first.sortOrder = 0
        var played = RadioStation(name: "B Played", streamURL: "https://radio.example/b")
        played.sortOrder = 1_024
        played.lastPlayedAt = Date(timeIntervalSince1970: 1_000)

        #expect(SiriRadioStationCatalog.defaultStation(from: [first, played], enabledSourceIDs: [])?.name == "B Played")
        #expect(SiriRadioStationCatalog.defaultStation(from: [first], enabledSourceIDs: [])?.name == "A First")
        #expect(SiriRadioStationCatalog.defaultStation(from: [], enabledSourceIDs: []) == nil)
    }

    @Test("Equally good station matches are settled without asking: last listened first")
    func preferredStation() throws {
        var first = RadioStation(id: "a", name: "交通广播", streamURL: "https://radio.example/a")
        first.sortOrder = 0
        var second = RadioStation(id: "b", name: "交通广播", streamURL: "https://radio.example/b")
        second.sortOrder = 1_024
        let stations = [first, second]
        let items = SiriRadioStationCatalog.namedItems(from: stations, enabledSourceIDs: [])

        let tied = try #require(SiriNamedMediaResolver.resolve(query: "交通广播", namespace: "radio", items: items))
        #expect(tied.needsDisambiguation)
        #expect(SiriRadioStationCatalog.preferredStation(for: tied, in: stations)?.id == "a")

        second.lastPlayedAt = Date(timeIntervalSince1970: 1_000)
        #expect(SiriRadioStationCatalog.preferredStation(for: tied, in: [first, second])?.id == "b")

        let weak = try #require(SiriNamedMediaResolver.resolve(
            query: "交通",
            namespace: "radio",
            items: [SiriNamedMediaItem(id: "a", name: "北京交通广播")]
        ))
        #expect(weak.requiresConfirmation)
        #expect(SiriRadioStationCatalog.preferredStation(for: weak, in: stations)?.id == "a")
    }

    @Test("Alternatives follow the station Siri plays")
    func rankedStations() throws {
        var first = RadioStation(id: "a", name: "交通广播", streamURL: "https://radio.example/a")
        first.sortOrder = 0
        var second = RadioStation(id: "b", name: "交通广播", streamURL: "https://radio.example/b")
        second.sortOrder = 1_024
        second.lastPlayedAt = Date(timeIntervalSince1970: 1_000)
        let third = RadioStation(id: "c", name: "北京交通广播", streamURL: "https://radio.example/c")
        let stations = [first, second, third]
        let items = SiriRadioStationCatalog.namedItems(from: stations, enabledSourceIDs: [])

        let tied = try #require(SiriNamedMediaResolver.resolve(query: "交通广播", namespace: "radio", items: items))
        #expect(SiriRadioStationCatalog.rankedStations(for: tied, in: stations).map(\.id) == ["b", "a"])

        let exact = try #require(SiriNamedMediaResolver.resolve(query: "北京交通广播", namespace: "radio", items: items))
        let ranked = SiriRadioStationCatalog.rankedStations(for: exact, in: stations)
        #expect(ranked.first?.id == "c")
        #expect(Set(ranked.dropFirst().map(\.id)) == ["a", "b"])
        #expect(SiriRadioStationCatalog.rankedStations(for: exact, in: stations, limit: 1).map(\.id) == ["c"])
    }

    @Test("A station chosen by name equality or prefix is a strong match")
    func namedMatchStrength() throws {
        let items = [
            SiriNamedMediaItem(id: "jazz", name: "Jazz FM"),
            SiriNamedMediaItem(id: "news", name: "City News Radio"),
        ]

        let exact = try #require(SiriNamedMediaResolver.resolve(query: "jazz fm", namespace: "radio", items: items))
        #expect(exact.isStrongMatch)
        let prefix = try #require(SiriNamedMediaResolver.resolve(query: "Jazz", namespace: "radio", items: items))
        #expect(prefix.isStrongMatch)
        let contained = try #require(SiriNamedMediaResolver.resolve(query: "News", namespace: "radio", items: items))
        #expect(!contained.isStrongMatch)
        #expect(contained.requiresConfirmation)
        let selected = try #require(SiriNamedMediaResolver.resolve(
            query: nil,
            selectedItemIDs: ["radio:news"],
            namespace: "radio",
            items: items
        ))
        #expect(selected.isStrongMatch)
    }

    private func serverStation(
        sourceID: String,
        serverID: String,
        name: String,
        sourceName: String = "Server"
    ) -> RadioStation {
        RadioStation(
            id: ServerRadioStationIdentity.stationID(
                sourceID: sourceID,
                serverStationID: serverID
            ),
            name: name,
            streamURL: "",
            sourceID: sourceID,
            serverStationID: serverID,
            sourceName: sourceName,
            sourcePlaybackPath: ServerRadioStationIdentity.mediaServerPlaybackPath(
                serverStationID: serverID
            )
        )
    }
}
