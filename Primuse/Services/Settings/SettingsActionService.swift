import Foundation
import PrimuseKit

struct SettingStatus {
    var value: String?
    var reason: String?
    var spokenDescription: String { [value, reason].compactMap { $0 }.joined(separator: ". ") }
}

enum SettingsActionError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

@MainActor
struct SettingsActionService {
    let playback: PlaybackSettingsStore
    var defaults: UserDefaults = .standard
    var effects: AudioEffectsService? = nil
    var showsIntelligence = true

    nonisolated static let toggleIDs: Set<String> = [
        "playback.matchSampleRate", "playback.gapless", "playback.crossfade",
        "playback.skipLeadingSilence", "playback.skipTrailingSilence", "playback.replayGain",
        "playback.spatialAudio", "playback.headTracking", "lyrics.lockScreen",
        "storage.audioCacheEnabled", "effects.chain", "effects.reverb", "effects.compressor",
        "lyrics.translationEnabled", "lyrics.tapToSeek", "lyrics.blurInactive", "lyrics.keepScreenAwake",
        "appearance.volumeBar"
    ]
    nonisolated static let readableIDs = toggleIDs.union([
        "playback.outputMode", "playback.dsdMode", "playback.crossfadeMode", "playback.crossfadeDuration",
        "playback.replayGainMode", "playback.speed", "storage.audioCacheLimit", "playback.prewarmQueue",
        "lyrics.translationTarget", "lyrics.translationMode", "about.version", "about.build"
    ])
    private static let effectsOnly: Set<String> = [
        "playback.matchSampleRate", "playback.crossfade", "playback.crossfadeMode", "playback.crossfadeDuration",
        "playback.skipLeadingSilence", "playback.skipTrailingSilence", "playback.replayGain", "playback.replayGainMode",
        "playback.spatialAudio", "playback.headTracking", "playback.speed", "playback.resetSpeed"
    ]

    func status(for id: String) -> SettingStatus {
        var value: String?
        if let enabled = booleanValue(for: id) {
            value = SettingsStrings.text(enabled ? "Enabled" : "Disabled")
        } else {
            switch id {
            case "playback.outputMode": value = playback.outputMode.displayName
            case "playback.dsdMode": value = playback.dsdPlaybackMode.displayName
            case "playback.crossfadeMode": value = playback.crossfadeMode.displayName
            case "playback.crossfadeDuration": value = String(format: "%.0f s", playback.crossfadeDuration)
            case "playback.replayGainMode": value = playback.replayGainMode.displayName
            case "playback.speed": value = String(format: "%.2f×", effectivePlaybackRate)
            case "playback.prewarmQueue": value = String(playback.prewarmQueueCount)
            case "storage.audioCacheLimit":
                value = playback.audioCacheLimitBytes == AudioCacheLimitPolicy.unlimitedBytes
                    ? String(localized: "smart_limit_placeholder")
                    : ByteCountFormatter.string(fromByteCount: playback.audioCacheLimitBytes, countStyle: .binary)
            case "lyrics.translationTarget":
                let code = LyricsTranslationSettingsStore.shared.targetLanguageCode
                value = Locale.current.localizedString(forIdentifier: code) ?? code
            case "lyrics.translationMode":
                value = String(localized: !showsIntelligence || LyricsTranslationSettingsStore.shared.mode == .system
                               ? "lyrics_translation_mode_system" : "lyrics_translation_mode_intelligent")
            case "about.version": value = Bundle.main.appVersion
            case "about.build": value = Bundle.main.appBuildNumber
            default: break
            }
        }
        return SettingStatus(value: value, reason: unavailableReason(for: id))
    }

    var effectivePlaybackRate: Float { playback.outputMode == .highFidelity ? 1 : playback.playbackRate }

    func unavailableReason(for id: String) -> String? {
        var needsEffects = Self.effectsOnly.contains(id) || id.hasPrefix("effects.") || id.hasPrefix("equalizer.") || ["page.effects", "page.equalizer"].contains(id)
        #if os(macOS)
        needsEffects = needsEffects || id == "playback.gapless"
        #endif
        if needsEffects, playback.outputMode == .highFidelity {
            return String(format: SettingsStrings.text("Unavailable in High Fidelity mode. Change the output mode in %@."), SettingsPage.playback.title)
        }
        #if os(macOS)
        if id.hasPrefix("effects."), id != "effects.chain", !playback.effectChainEnabled {
            return SettingsStrings.text("Enable the effects chain to adjust this setting.")
        }
        #endif
        if ["playback.crossfadeMode", "playback.crossfadeDuration"].contains(id), !playback.crossfadeEnabled {
            return SettingsStrings.text("Enable crossfade to adjust this setting.")
        }
        if id == "playback.replayGainMode", !playback.replayGainEnabled {
            return SettingsStrings.text("Enable ReplayGain to adjust this setting.")
        }
        if id == "playback.headTracking", !playback.spatialAudioEnabled {
            return SettingsStrings.text("Enable spatial audio to adjust head tracking.")
        }
        if id.hasPrefix("effects.reverb"), id != "effects.reverb", !playback.reverbEnabled {
            return SettingsStrings.text("Enable reverb to adjust this setting.")
        }
        if id.hasPrefix("effects.compressor"), id != "effects.compressor", !playback.compressorEnabled {
            return SettingsStrings.text("Enable the compressor to adjust this setting.")
        }
        if ["lyrics.translationMode", "lyrics.translationTarget", "lyrics.translationCache", "lyrics.clearTranslationCache"].contains(id),
           !LyricsTranslationSettingsStore.shared.isEnabled {
            return SettingsStrings.text("Enable lyrics translation to adjust this setting.")
        }
        return SettingsCatalog.byID[id]?.hint.map(SettingsStrings.text)
    }

    func booleanValue(for id: String) -> Bool? {
        switch id {
        case "playback.matchSampleRate": playback.outputMode == .highFidelity || playback.matchOutputSampleRate
        case "playback.gapless": playback.gaplessEnabled
        case "playback.crossfade": playback.crossfadeEnabled
        case "playback.skipLeadingSilence": playback.skipLeadingSilenceEnabled
        case "playback.skipTrailingSilence": playback.skipTrailingSilenceEnabled
        case "playback.replayGain": playback.replayGainEnabled
        case "playback.spatialAudio": playback.spatialAudioEnabled
        case "playback.headTracking": playback.spatialHeadTrackingEnabled
        case "lyrics.lockScreen": playback.lockScreenLyricsEnabled
        case "storage.audioCacheEnabled": playback.audioCacheEnabled
        case "effects.chain": playback.effectChainEnabled
        case "effects.reverb": playback.reverbEnabled
        case "effects.compressor": playback.compressorEnabled
        case "lyrics.translationEnabled": LyricsTranslationSettingsStore.shared.isEnabled
        case "lyrics.tapToSeek": preference(PlayerAppearancePreferences.tapLyricsToSeekKey, fallback: PlayerAppearancePreferences.tapLyricsToSeekByDefault)
        case "lyrics.blurInactive": preference(PlayerAppearancePreferences.blursInactiveLyricsKey, fallback: PlayerAppearancePreferences.blursInactiveLyricsByDefault)
        case "lyrics.keepScreenAwake": preference(PlayerAppearancePreferences.keepsScreenAwakeForLyricsKey, fallback: PlayerAppearancePreferences.keepsScreenAwakeForLyricsByDefault)
        case "appearance.volumeBar": preference(PlayerAppearancePreferences.showsVolumeBarKey, fallback: PlayerAppearancePreferences.showsVolumeBarByDefault)
        default: nil
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for id: String) throws -> SettingStatus {
        guard Self.toggleIDs.contains(id), SettingsCatalog.byID[id] != nil else {
            throw SettingsActionError.unavailable(SettingsStrings.text("Open this setting in the app to make changes."))
        }
        if let reason = unavailableReason(for: id) { throw SettingsActionError.unavailable(reason) }
        let disablesGapless = id == "playback.crossfade" && enabled && playback.gaplessEnabled
        let disablesCrossfade = id == "playback.gapless" && enabled && playback.crossfadeEnabled
        switch id {
        case "playback.matchSampleRate": playback.matchOutputSampleRate = enabled
        case "playback.gapless": playback.gaplessEnabled = enabled
        case "playback.crossfade": playback.crossfadeEnabled = enabled
        case "playback.skipLeadingSilence": playback.skipLeadingSilenceEnabled = enabled
        case "playback.skipTrailingSilence": playback.skipTrailingSilenceEnabled = enabled
        case "playback.replayGain": playback.replayGainEnabled = enabled
        case "playback.spatialAudio": playback.spatialAudioEnabled = enabled
        case "playback.headTracking": playback.spatialHeadTrackingEnabled = enabled
        case "lyrics.lockScreen": playback.lockScreenLyricsEnabled = enabled
        case "storage.audioCacheEnabled": playback.audioCacheEnabled = enabled
        case "effects.chain", "effects.reverb", "effects.compressor":
            try setAudioEffect(enabled, for: id)
        case "lyrics.translationEnabled": LyricsTranslationSettingsStore.shared.isEnabled = enabled
        case "lyrics.tapToSeek": defaults.set(enabled, forKey: PlayerAppearancePreferences.tapLyricsToSeekKey)
        case "lyrics.blurInactive": defaults.set(enabled, forKey: PlayerAppearancePreferences.blursInactiveLyricsKey)
        case "lyrics.keepScreenAwake": defaults.set(enabled, forKey: PlayerAppearancePreferences.keepsScreenAwakeForLyricsKey)
        case "appearance.volumeBar": defaults.set(enabled, forKey: PlayerAppearancePreferences.showsVolumeBarKey)
        default: throw SettingsActionError.unavailable(SettingsStrings.text("Open this setting in the app to make changes."))
        }
        var result = status(for: id)
        if disablesGapless { result.reason = SettingsStrings.text("Gapless playback was turned off.") }
        if disablesCrossfade { result.reason = SettingsStrings.text("Crossfade was turned off.") }
        return result
    }

    private func setAudioEffect(_ enabled: Bool, for id: String) throws {
        guard let effects else {
            throw SettingsActionError.unavailable(SettingsStrings.text("Open this setting in the app to make changes."))
        }
        // The live service updates the audio nodes and persists to the same settings store.
        switch id {
        case "effects.chain": effects.effectChainEnabled = enabled
        case "effects.reverb": effects.reverbEnabled = enabled
        case "effects.compressor": effects.compressorEnabled = enabled
        default: break
        }
    }

    private func preference(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
