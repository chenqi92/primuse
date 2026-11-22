import PrimuseKit
import SwiftUI

struct LyricsCompanionTrackButtons: View {
    let tracks: LyricBundledTranslationPolicy.Tracks
    let foreground: Color
    let fill: Color
    var onInteraction: (() -> Void)? = nil

    var body: some View {
        if !tracks.isEmpty {
            HStack(spacing: 6) {
                if tracks.contains(.translation) {
                    let settings = LyricsTranslationSettingsStore.shared
                    button(title: "lyrics_translation_section", accessibilityTitle: "lyrics_bundled_translation_shown",
                           isOn: settings.showsBundledTranslations, identifier: "lyricsBundledTranslationToggle") {
                        settings.showsBundledTranslations.toggle()
                    }
                }
                if tracks.contains(.romanization) {
                    let settings = LyricsRomanizationSettingsStore.shared
                    button(title: "lyrics_romanization_section", accessibilityTitle: "lyrics_romanization_display",
                           isOn: settings.displayMode != .hidden, identifier: "lyricsRomanizationToggle") {
                        settings.toggleVisibility()
                    }
                }
            }
        }
    }

    private func button(title: LocalizedStringKey, accessibilityTitle: LocalizedStringKey,
                        isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            onInteraction?()
            action()
        } label: {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
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
}
