import AppIntents
import Foundation
import PrimuseKit

private enum PrimuseRadioStationEntityIdentifier {
    private static let confirmationMarker = "confirm|"
    private static let selectionMarker = "selected|"

    static func make(stationID: String, requiresConfirmation: Bool) -> String {
        let marker = requiresConfirmation ? confirmationMarker : selectionMarker
        let value = marker + stationID
        return SiriMediaIdentifier.namespaced(value, as: "radio")
    }

    static func parse(_ identifier: String) -> (stationID: String, requiresConfirmation: Bool)? {
        guard var value = SiriMediaIdentifier.value(
            from: identifier,
            expectedNamespace: "radio"
        ) else {
            return nil
        }
        let requiresConfirmation = value.hasPrefix(confirmationMarker)
        if requiresConfirmation {
            value.removeFirst(confirmationMarker.count)
        } else if value.hasPrefix(selectionMarker) {
            value.removeFirst(selectionMarker.count)
        }
        guard SiriRadioStationCatalog.isSafeIdentifier(value) else { return nil }
        return (value, requiresConfirmation)
    }
}

struct PrimuseRadioStationEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Radio Station")
    static let defaultQuery = PrimuseRadioStationEntityQuery()

    let id: String
    let name: String
    let sourceName: String?
    let requiresPlaybackConfirmation: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: sourceName.map { "\($0)" }
        )
    }
}

struct PrimuseRadioStationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PrimuseRadioStationEntity] {
        await MainActor.run {
            let store = AppServices.shared.radioStationsStore
            var seen = Set<String>()
            return identifiers.compactMap { identifier in
                guard let parsed = PrimuseRadioStationEntityIdentifier.parse(identifier),
                   seen.insert(identifier).inserted,
                   let station = store.station(id: parsed.stationID),
                   SiriRadioStationCatalog.safeDisplayName(station.name) != nil else {
                    return nil
                }
                return Self.entity(
                    for: station,
                    requiresPlaybackConfirmation: parsed.requiresConfirmation
                )
            }
        }
    }

    func entities(matching string: String) async throws -> [PrimuseRadioStationEntity] {
        await MainActor.run {
            let services = AppServices.shared
            guard let result = SiriNamedMediaResolver.resolve(
                query: string,
                namespace: "radio",
                items: services.siriRadioItems
            ) else {
                return []
            }
            let selectedItems = result.needsDisambiguation
                ? result.candidates
                : [result.selected]
            let stationsByID = Dictionary(
                services.siriRadioStations.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return selectedItems.compactMap { item in
                stationsByID[item.id].map {
                    Self.entity(
                        for: $0,
                        requiresPlaybackConfirmation: result.requiresConfirmation
                    )
                }
            }
        }
    }

    func suggestedEntities() async throws -> [PrimuseRadioStationEntity] {
        await MainActor.run {
            AppServices.shared.siriRadioStations.prefix(20).map {
                Self.entity(for: $0)
            }
        }
    }

    private static func entity(
        for station: RadioStation,
        requiresPlaybackConfirmation: Bool = false
    ) -> PrimuseRadioStationEntity {
        PrimuseRadioStationEntity(
            id: PrimuseRadioStationEntityIdentifier.make(
                stationID: station.id,
                requiresConfirmation: requiresPlaybackConfirmation
            ),
            name: SiriRadioStationCatalog.safeDisplayName(station.name) ?? station.name,
            sourceName: safeSourceName(station.sourceName),
            requiresPlaybackConfirmation: requiresPlaybackConfirmation
        )
    }

    private static func safeSourceName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 80 else {
            return nil
        }
        let forbidden = ["://", "?", "&", "=", "@", "\\"]
        return forbidden.contains(where: value.contains) ? nil : value
    }
}

struct PrimusePlayRadioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Radio Station"
    static let description = IntentDescription("Play a saved internet-radio station in Primuse.")

    @Parameter(title: "Station")
    var station: PrimuseRadioStationEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let parsedIdentifier = PrimuseRadioStationEntityIdentifier.parse(station.id),
              let currentStation = AppServices.shared.radioStationsStore.station(
                  id: parsedIdentifier.stationID
              ),
              let safeStationName = SiriRadioStationCatalog.safeDisplayName(
                  currentStation.name
              ) else {
            return .result(dialog: IntentDialog("No matching saved radio station."))
        }
        if parsedIdentifier.requiresConfirmation || station.requiresPlaybackConfirmation {
            let message = String(
                format: String(localized: "intent_radio_confirm_format"),
                safeStationName
            )
            let confirmationEntity = PrimuseRadioStationEntity(
                id: station.id,
                name: safeStationName,
                sourceName: nil,
                requiresPlaybackConfirmation: true
            )
            guard try await $station.requestConfirmation(
                for: confirmationEntity,
                dialog: IntentDialog(LocalizedStringResource(stringLiteral: message))
            ) else {
                return .result(dialog: IntentDialog("Radio playback was cancelled."))
            }
        }
        let outcome = await PrimuseIntentBridge.shared.playRadioStation(
            parsedIdentifier.stationID
        )
        switch outcome {
        case .playing(let name):
            let message = String(
                format: String(localized: "intent_playing_radio_format"),
                name
            )
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
        case .notFound:
            return .result(dialog: IntentDialog("No matching saved radio station."))
        case .sourceDisabled:
            return .result(dialog: IntentDialog("The radio station's source is disabled."))
        case .unavailable:
            return .result(dialog: IntentDialog("The radio station is currently unavailable."))
        }
    }
}

/// macOS has no `INSearchForMediaIntent`, so an App Shortcut supplies the same
/// local-catalog search surface. iOS and tvOS use the system media-search intent.
struct PrimuseSearchRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Radio Stations"
    static let description = IntentDescription("Search saved radio stations in Primuse without starting playback.")

    @Parameter(title: "Radio Station")
    var station: PrimuseRadioStationEntity?

    @Parameter(title: "Keyword")
    var query: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches: [SiriNamedMediaItem]
        if let station {
            if let parsed = PrimuseRadioStationEntityIdentifier.parse(station.id),
               let selected = services.siriRadioItems.first(where: {
                   $0.id == parsed.stationID
               }) {
                matches = [selected]
            } else {
                matches = []
            }
        } else if trimmed.isEmpty {
            matches = Array(services.siriRadioItems.prefix(5))
        } else if let result = SiriNamedMediaResolver.resolve(
            query: trimmed,
            namespace: "radio",
            items: services.siriRadioItems
        ) {
            matches = Array(result.candidates.prefix(5))
        } else {
            matches = []
        }

        guard !matches.isEmpty else {
            return .result(dialog: IntentDialog("No matching saved radio station."))
        }
        let names = ListFormatter.localizedString(byJoining: matches.map(\.name))
        let message = String(
            format: String(localized: "intent_radio_search_results_format"),
            names
        )
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
    }
}

@MainActor
extension AppServices {
    var siriRadioStations: [RadioStation] {
        SiriRadioStationCatalog.availableStations(
            from: radioStationsStore.stations,
            enabledSourceIDs: Set(sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        )
    }

    var siriRadioItems: [SiriNamedMediaItem] {
        SiriRadioStationCatalog.namedItems(
            from: radioStationsStore.stations,
            enabledSourceIDs: Set(sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        )
    }
}
