import PrimuseKit
import SwiftUI

extension LyricDuetLayoutPolicy.Side {
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var flowAlignment: LyricFlowHorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

struct LyricsCompanionTrackButtons: View {
    let tracks: LyricBundledTranslationPolicy.Tracks
    var catalog: LyricTrackCatalog = .empty
    var songID: String? = nil
    let foreground: Color
    let fill: Color
    var onInteraction: (() -> Void)? = nil

    private var showsLanguage: Bool { catalog.hasReplacementTracks }
    private var showsTranslation: Bool { tracks.contains(.translation) || catalog.hasSubtitleTracks }
    private var showsTransliteration: Bool { tracks.contains(.romanization) || catalog.hasTransliteration }

    var body: some View {
        if showsLanguage || showsTranslation || showsTransliteration {
            let trackStore = LyricsTrackSelectionStore.shared
            let selection = trackStore.selection(forSongID: songID)
            let translationSettings = LyricsTranslationSettingsStore.shared
            let romanizationSettings = LyricsRomanizationSettingsStore.shared
            HStack(spacing: 6) {
                if showsLanguage {
                    languageControl(
                        selection: selection,
                        trackStore: trackStore,
                        romanizationSettings: romanizationSettings
                    )
                }
                if showsTranslation {
                    translationControl(
                        selection: selection,
                        trackStore: trackStore,
                        settings: translationSettings
                    )
                }
                if showsTransliteration {
                    transliterationControl(
                        selection: selection,
                        trackStore: trackStore,
                        settings: romanizationSettings
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func languageControl(
        selection: LyricTrackSelection,
        trackStore: LyricsTrackSelectionStore,
        romanizationSettings: LyricsRomanizationSettingsStore
    ) -> some View {
        let isRomanizationPrimary = showsTransliteration && romanizationSettings.displayMode == .romanizationOnly
        let activeReplacementID = selection.replacementTrackID.flatMap { id in
            catalog.replacementTracks.contains(where: { $0.id == id }) ? id : nil
        }
        let originalTitle = LyricTrackSelectionPolicy.originalDisplayName(
            for: catalog,
            originalFallback: String(localized: "lyrics_track_original")
        )
        let activeValueTitle: String = {
            if isRomanizationPrimary {
                return String(localized: "lyrics_romanization_display_only")
            }
            if let activeReplacementID,
               let track = catalog.replacementTracks.first(where: { $0.id == activeReplacementID }) {
                return LyricTrackSelectionPolicy.displayName(
                    forLanguageCode: track.languageCode,
                    fallback: String(localized: "lyrics_track_language")
                )
            }
            return originalTitle
        }()
        let isSelected = activeReplacementID != nil || isRomanizationPrimary

        menuControl(
            title: "lyrics_track_language",
            accessibilityTitle: "lyrics_track_language",
            accessibilityValue: Text(verbatim: activeValueTitle),
            systemImage: "globe",
            isSelected: isSelected,
            identifier: "lyricsPrimaryLanguageMenu"
        ) {
            menuChoice(originalTitle, checked: !isRomanizationPrimary && activeReplacementID == nil) {
                onInteraction?()
                trackStore.selectReplacement(nil, forSongID: songID)
            }
            ForEach(catalog.replacementTracks) { track in
                let label = LyricTrackSelectionPolicy.displayName(
                    forLanguageCode: track.languageCode,
                    fallback: String(localized: "lyrics_track_language")
                )
                menuChoice(label, checked: !isRomanizationPrimary && activeReplacementID == track.id) {
                    onInteraction?()
                    trackStore.selectReplacement(track.id, forSongID: songID)
                }
            }
            if showsTransliteration {
                Divider()
                menuChoice(String(localized: "lyrics_romanization_display_only"), checked: isRomanizationPrimary) {
                    onInteraction?()
                    trackStore.selectRomanizationAsPrimary(forSongID: songID)
                }
            }
        }
    }

    @ViewBuilder
    private func translationControl(
        selection: LyricTrackSelection,
        trackStore: LyricsTrackSelectionStore,
        settings: LyricsTranslationSettingsStore
    ) -> some View {
        let isOn = settings.showsBundledTranslations
        if catalog.subtitleTracks.count > 1 {
            let activeSubtitleID = isOn
                ? LyricTrackSelectionPolicy.resolvedSubtitleTrackID(
                    in: catalog,
                    selected: selection.subtitleTrackID,
                    targetLanguageCode: settings.targetLanguageCode,
                    preferredLanguages: Locale.preferredLanguages
                )
                : nil
            menuControl(
                title: "lyrics_translation_section",
                accessibilityTitle: "lyrics_bundled_translation_shown",
                accessibilityValue: Text(isOn ? "a11y_value_on" : "a11y_value_off"),
                systemImage: isOn ? "checkmark.circle.fill" : "circle",
                isSelected: isOn,
                identifier: "lyricsBundledTranslationToggle"
            ) {
                menuChoice(String(localized: "lyrics_track_off"), checked: !isOn) {
                    onInteraction?()
                    trackStore.selectSubtitle(nil, forSongID: songID)
                }
                Divider()
                ForEach(catalog.subtitleTracks) { track in
                    let label = LyricTrackSelectionPolicy.displayName(
                        forLanguageCode: track.languageCode,
                        fallback: String(localized: "lyrics_translation_section")
                    )
                    menuChoice(label, checked: isOn && activeSubtitleID == track.id) {
                        onInteraction?()
                        trackStore.selectSubtitle(track.id, forSongID: songID)
                    }
                }
            }
        } else {
            button(
                title: "lyrics_translation_section",
                accessibilityTitle: "lyrics_bundled_translation_shown",
                isOn: isOn,
                identifier: "lyricsBundledTranslationToggle"
            ) {
                settings.showsBundledTranslations.toggle()
            }
        }
    }

    @ViewBuilder
    private func transliterationControl(
        selection: LyricTrackSelection,
        trackStore: LyricsTrackSelectionStore,
        settings: LyricsRomanizationSettingsStore
    ) -> some View {
        let mode = settings.displayMode
        let isOn = mode != .hidden
        if !catalog.isEmpty {
            let activeTrackID = LyricTrackSelectionPolicy.resolvedTransliterationTrackID(
                in: catalog,
                selected: selection.transliterationTrackID
            )
            menuControl(
                title: "lyrics_romanization_section",
                accessibilityTitle: "lyrics_romanization_display",
                accessibilityValue: Text(isOn ? "a11y_value_on" : "a11y_value_off"),
                systemImage: isOn ? "checkmark.circle.fill" : "circle",
                isSelected: isOn,
                identifier: "lyricsRomanizationToggle"
            ) {
                menuChoice(String(localized: "lyrics_romanization_display_hidden"), checked: mode == .hidden) {
                    onInteraction?()
                    trackStore.selectTransliterationMode(.hidden, forSongID: songID)
                }
                menuChoice(String(localized: "lyrics_romanization_display_below"), checked: mode == .belowOriginal) {
                    onInteraction?()
                    trackStore.selectTransliterationMode(.belowOriginal, forSongID: songID)
                }
                menuChoice(String(localized: "lyrics_romanization_display_only"), checked: mode == .romanizationOnly) {
                    onInteraction?()
                    trackStore.selectRomanizationAsPrimary(forSongID: songID)
                }
                if catalog.transliterationTracks.count > 1 {
                    Divider()
                    ForEach(catalog.transliterationTracks) { track in
                        let label = LyricTrackSelectionPolicy.displayName(
                            forLanguageCode: track.languageCode,
                            fallback: String(localized: "lyrics_romanization_section")
                        )
                        menuChoice(label, checked: isOn && activeTrackID == track.id) {
                            onInteraction?()
                            trackStore.selectTransliteration(track.id, forSongID: songID)
                        }
                    }
                }
            }
        } else {
            button(
                title: "lyrics_romanization_section",
                accessibilityTitle: "lyrics_romanization_display",
                isOn: isOn,
                identifier: "lyricsRomanizationToggle"
            ) {
                settings.toggleVisibility()
            }
        }
    }

    private func menuChoice(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(verbatim: title)
            }
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func menuControl<MenuContent: View>(
        title: LocalizedStringKey,
        accessibilityTitle: LocalizedStringKey,
        accessibilityValue: Text,
        systemImage: String,
        isSelected: Bool,
        identifier: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu {
            content()
        } label: {
            pillLabel(title: title, systemImage: systemImage)
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        .controlSize(.small)
        #elseif os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(accessibilityTitle))
        #else
        .buttonStyle(.plain)
        .help(Text(accessibilityTitle))
        #endif
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func button(
        title: LocalizedStringKey,
        accessibilityTitle: LocalizedStringKey,
        isOn: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onInteraction?()
            action()
        } label: {
            pillLabel(title: title, systemImage: isOn ? "checkmark.circle.fill" : "circle")
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        .controlSize(.small)
        #else
        .buttonStyle(.plain)
        .help(Text(accessibilityTitle))
        #endif
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(isOn ? "a11y_value_on" : "a11y_value_off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func pillLabel(title: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
        }
        #if !os(tvOS)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(fill, in: Capsule())
        #if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        #endif
        #endif
    }
}
