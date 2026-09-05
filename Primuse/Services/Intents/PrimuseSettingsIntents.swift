import AppIntents
import Foundation
import PrimuseKit

struct PrimuseSettingEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Setting", table: "SettingsSearch"))
    static let defaultQuery = PrimuseSettingQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation {
        let item = SettingsCatalog.byID[id]
        return DisplayRepresentation(title: "\(item?.title ?? SettingsStrings.text("Setting"))", subtitle: "\(item?.path ?? "")")
    }
}

struct PrimuseSettingQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PrimuseSettingEntity] {
        identifiers.filter { SettingsCatalog.byID[$0] != nil }.map { .init(id: $0) }
    }
    func entities(matching string: String) async throws -> [PrimuseSettingEntity] {
        SettingsCatalog.search(string).map { .init(id: $0.id) }
    }
    func suggestedEntities() async throws -> [PrimuseSettingEntity] {
        SettingsCatalog.available.map { .init(id: $0.id) }
    }
}

struct PrimuseReadableSettingEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Setting", table: "SettingsSearch"))
    static let defaultQuery = PrimuseReadableSettingQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { PrimuseSettingEntity(id: id).displayRepresentation }
}

struct PrimuseReadableSettingQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PrimuseReadableSettingEntity] {
        identifiers.filter { SettingsActionService.readableIDs.contains($0) && SettingsCatalog.byID[$0] != nil }.map { .init(id: $0) }
    }
    func entities(matching string: String) async throws -> [PrimuseReadableSettingEntity] {
        SettingsCatalog.search(string).filter { SettingsActionService.readableIDs.contains($0.id) }.map { .init(id: $0.id) }
    }
    func suggestedEntities() async throws -> [PrimuseReadableSettingEntity] {
        SettingsCatalog.available.filter { SettingsActionService.readableIDs.contains($0.id) }.map { .init(id: $0.id) }
    }
}

struct PrimuseToggleSettingEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Setting", table: "SettingsSearch"))
    static let defaultQuery = PrimuseToggleSettingQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { PrimuseSettingEntity(id: id).displayRepresentation }
}

struct PrimuseToggleSettingQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PrimuseToggleSettingEntity] {
        identifiers.filter { SettingsActionService.toggleIDs.contains($0) && SettingsCatalog.byID[$0] != nil }.map { .init(id: $0) }
    }
    func entities(matching string: String) async throws -> [PrimuseToggleSettingEntity] {
        SettingsCatalog.search(string).filter { SettingsActionService.toggleIDs.contains($0.id) }.map { .init(id: $0.id) }
    }
    func suggestedEntities() async throws -> [PrimuseToggleSettingEntity] {
        SettingsCatalog.available.filter { SettingsActionService.toggleIDs.contains($0.id) }.map { .init(id: $0.id) }
    }
}

struct PrimuseOpenSettingIntent: OpenIntent {
    static let title = LocalizedStringResource("Open Setting", table: "SettingsSearch")
    static let description = IntentDescription(LocalizedStringResource("Open a specific Primuse setting without changing it.", table: "SettingsSearch"), categoryName: LocalizedStringResource("Settings", table: "SettingsSearch"))
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: LocalizedStringResource("Setting", table: "SettingsSearch")) var target: PrimuseSettingEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)", table: "SettingsSearch") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let item = SettingsCatalog.byID[target.id],
              item.page != .intelligence || AppServices.shared.musicIntelligence.shouldExposeRemoteConfiguration else {
            throw SettingsActionError.unavailable(SettingsStrings.text("This setting is unavailable on this device."))
        }
        SettingsNavigation.shared.open(item.id)
        return .result()
    }
}

struct PrimuseGetSettingIntent: AppIntent {
    static let title = LocalizedStringResource("Get Setting", table: "SettingsSearch")
    static let description = IntentDescription(LocalizedStringResource("Read a Primuse setting and its current availability.", table: "SettingsSearch"), categoryName: LocalizedStringResource("Settings", table: "SettingsSearch"))
    @Parameter(title: LocalizedStringResource("Setting", table: "SettingsSearch")) var setting: PrimuseReadableSettingEntity
    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$setting)", table: "SettingsSearch") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard SettingsActionService.readableIDs.contains(setting.id), let item = SettingsCatalog.byID[setting.id] else {
            throw SettingsActionError.unavailable(SettingsStrings.text("This setting is unavailable on this device."))
        }
        let status = SettingsActionService(
            playback: AppServices.shared.playbackSettingsStore,
            effects: AppServices.shared.playerService.audioEffectsService,
            showsIntelligence: AppServices.shared.musicIntelligence.shouldExposeRemoteConfiguration
        ).status(for: item.id)
        let response = item.title + ": " + status.spokenDescription
        return .result(value: status.spokenDescription, dialog: IntentDialog(LocalizedStringResource(stringLiteral: response)))
    }
}

struct PrimuseSetSettingIntent: AppIntent {
    static let title = LocalizedStringResource("Set Setting", table: "SettingsSearch")
    static let description = IntentDescription(LocalizedStringResource("Turn a supported Primuse setting on or off.", table: "SettingsSearch"), categoryName: LocalizedStringResource("Settings", table: "SettingsSearch"))
    @Parameter(title: LocalizedStringResource("Setting", table: "SettingsSearch")) var setting: PrimuseToggleSettingEntity
    @Parameter(title: LocalizedStringResource("Enabled", table: "SettingsSearch")) var enabled: Bool
    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$setting) to \(\.$enabled)", table: "SettingsSearch") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = SettingsActionService(
            playback: AppServices.shared.playbackSettingsStore,
            effects: AppServices.shared.playerService.audioEffectsService,
            showsIntelligence: AppServices.shared.musicIntelligence.shouldExposeRemoteConfiguration
        )
        let status = try service.setEnabled(enabled, for: setting.id)
        let response = (SettingsCatalog.byID[setting.id]?.title ?? "") + ": " + status.spokenDescription
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: response)))
    }
}

enum PrimuseSettingsOutputMode: String, AppEnum {
    case highFidelity, effects
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "audio_output_mode")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .highFidelity: "output_mode_high_fidelity", .effects: "output_mode_effects"
    ]
}

struct PrimuseSetOutputModeIntent: AppIntent {
    static let title = LocalizedStringResource("Set Audio Output Mode", table: "SettingsSearch")
    @Parameter(title: "audio_output_mode") var mode: PrimuseSettingsOutputMode
    static var parameterSummary: some ParameterSummary { Summary("Set audio output to \(\.$mode)", table: "SettingsSearch") }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = AppServices.shared.playbackSettingsStore
        settings.outputMode = mode == .highFidelity ? .highFidelity : .effects
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: settings.outputMode.displayName)))
    }
}
