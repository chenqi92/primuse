import Foundation
import Observation
import PrimuseKit

@MainActor
@Observable
final class ArtistNameSettingsStore {
    static let shared = ArtistNameSettingsStore()

    private let defaults: UserDefaults
    private let syncsThroughICloud: Bool

    private(set) var configuration: ArtistNameConfiguration
    private(set) var hasUnsupportedStoredConfiguration: Bool
    private(set) var revision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        syncsThroughICloud: Bool? = nil
    ) {
        self.defaults = defaults
        self.syncsThroughICloud = syncsThroughICloud ?? (defaults === UserDefaults.standard)
        let state = Self.loadState(from: defaults)
        configuration = state.configuration
        hasUnsupportedStoredConfiguration = state.hasUnsupportedValue

        if self.syncsThroughICloud {
            CloudKVSSync.shared.register(key: ArtistNameConfiguration.storageKey) { [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    @discardableResult
    func addSeparator(_ value: String) -> Bool {
        var next = configuration
        next.separators.append(value)
        return apply(next)
    }

    func removeSeparators(at offsets: IndexSet) {
        var next = configuration
        for offset in offsets.sorted(by: >) where next.separators.indices.contains(offset) {
            next.separators.remove(at: offset)
        }
        _ = apply(next)
    }

    @discardableResult
    func addProtectedName(_ value: String) -> Bool {
        var next = configuration
        next.protectedNames.append(value)
        return apply(next)
    }

    func removeProtectedNames(at offsets: IndexSet) {
        var next = configuration
        for offset in offsets.sorted(by: >) where next.protectedNames.indices.contains(offset) {
            next.protectedNames.remove(at: offset)
        }
        _ = apply(next)
    }

    func setDisplaySeparator(_ value: String) {
        var next = configuration
        next.displaySeparator = value
        _ = apply(next)
    }

    func resetToDefaults() {
        _ = apply(.defaultValue)
    }

    @discardableResult
    func apply(_ value: ArtistNameConfiguration) -> Bool {
        let value = value.normalized()
        guard value != configuration || hasUnsupportedStoredConfiguration else { return false }
        guard let data = try? value.encodedData() else { return false }

        defaults.set(data, forKey: ArtistNameConfiguration.storageKey)
        configuration = value
        hasUnsupportedStoredConfiguration = false
        revision &+= 1
        if syncsThroughICloud {
            CloudKVSSync.shared.markChanged(key: ArtistNameConfiguration.storageKey)
        }
        postChange(value)
        return true
    }

    private func reloadFromDefaults() {
        let state = Self.loadState(from: defaults)
        guard state.configuration != configuration
                || state.hasUnsupportedValue != hasUnsupportedStoredConfiguration else {
            return
        }
        configuration = state.configuration
        hasUnsupportedStoredConfiguration = state.hasUnsupportedValue
        revision &+= 1
        postChange(state.configuration)
    }

    private func postChange(_ value: ArtistNameConfiguration) {
        NotificationCenter.default.post(
            name: .primuseArtistNameConfigurationDidChange,
            object: value
        )
    }

    private static func loadState(
        from defaults: UserDefaults
    ) -> (configuration: ArtistNameConfiguration, hasUnsupportedValue: Bool) {
        let data = defaults.data(forKey: ArtistNameConfiguration.storageKey)
        let decoded = data.flatMap {
            try? JSONDecoder().decode(ArtistNameConfiguration.self, from: $0)
        }
        return (
            ArtistNameConfiguration.load(from: defaults),
            data != nil && (decoded == nil || decoded?.isSupported == false)
        )
    }
}
