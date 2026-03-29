import Foundation

enum ReplayGainMode: String, Codable, Sendable, CaseIterable {
    case track
    case album

    var displayName: String {
        switch self {
        case .track: String(localized: "rg_mode_track")
        case .album: String(localized: "rg_mode_album")
        }
    }
}

struct PlaybackSettings: Codable, Sendable {
    static let defaultsKey = "primuse_playback_settings_v1"

    var gaplessEnabled: Bool = true
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: Double = 3.0
    var replayGainEnabled: Bool = false
    var replayGainMode: ReplayGainMode = .track

    static func load(defaults: UserDefaults = .standard) -> PlaybackSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else {
            return PlaybackSettings()
        }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class PlaybackSettingsStore {
    var gaplessEnabled: Bool { didSet { persist() } }
    var crossfadeEnabled: Bool { didSet { persist() } }
    var crossfadeDuration: Double { didSet { persist() } }
    var replayGainEnabled: Bool { didSet { persist() } }
    var replayGainMode: ReplayGainMode { didSet { persist() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = PlaybackSettings.load(defaults: defaults)
        self.gaplessEnabled = s.gaplessEnabled
        self.crossfadeEnabled = s.crossfadeEnabled
        self.crossfadeDuration = s.crossfadeDuration
        self.replayGainEnabled = s.replayGainEnabled
        self.replayGainMode = s.replayGainMode
    }

    func snapshot() -> PlaybackSettings {
        PlaybackSettings(
            gaplessEnabled: gaplessEnabled,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDuration: crossfadeDuration,
            replayGainEnabled: replayGainEnabled,
            replayGainMode: replayGainMode
        )
    }

    private func persist() {
        snapshot().save(defaults: defaults)
    }
}
