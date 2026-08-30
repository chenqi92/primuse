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
