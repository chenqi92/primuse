#if os(macOS)
import SwiftUI
import PrimuseKit

/// Standard macOS Preferences window (⌘,). Each tab is one settings section
/// — flattened so SwiftUI's TabView toolbar shows a single row of icons,
/// the way native macOS preferences do (System Settings, Mail, Xcode etc).
///
/// Every tab is wrapped in `.topAligned()` so the content sits at the top
/// of the pane like every other macOS Settings window — without it, plain
/// VStack-based panes (PlaybackSettings, Equalizer, AudioEffects) drift
/// into the vertical center of the window and look untethered.
struct MacSettingsView: View {
    private enum Tab: String, Hashable {
        case general, equalizer, effects, library, sources, sync, recentlyDeleted, security, about
    }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            PlaybackSettingsView().topAligned()
                .tabItem { Label("playback_settings", systemImage: "play.circle") }
                .tag(Tab.general)

            EqualizerView().topAligned()
                .tabItem { Label("equalizer", systemImage: "slider.horizontal.3") }
                .tag(Tab.equalizer)

            AudioEffectsView().topAligned()
                .tabItem { Label("audio_effects", systemImage: "waveform.badge.plus") }
                .tag(Tab.effects)

            MacMetadataScrapingView()
                .tabItem { Label("metadata_scraping", systemImage: "wand.and.stars") }
                .tag(Tab.library)

            MacSourcesView()
                .tabItem { Label("manage_sources", systemImage: "externaldrive.connected.to.line.below") }
                .tag(Tab.sources)

            MacCloudSyncSettingsView()
                .tabItem { Label("icloud_sync_title", systemImage: "icloud") }
                .tag(Tab.sync)

            RecentlyDeletedView()
                .frame(minWidth: 720, minHeight: 520)
                .tabItem { Label("recently_deleted", systemImage: "trash") }
                .tag(Tab.recentlyDeleted)

            MacTrustedDomainsView()
                .tabItem { Label("trusted_domains", systemImage: "lock.shield") }
                .tag(Tab.security)

            aboutTab.topAligned()
                .tabItem { Label("about", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var aboutTab: some View {
        Form {
            LabeledContent("version", value: "1.1.0")
            LabeledContent("build", value: "5")
            NavigationLink("licenses") { LicensesView() }
        }
        .formStyle(.grouped)
    }
}

private extension View {
    /// Pin content to the top of its container with consistent macOS-style
    /// padding. Form/List-backed panes (which already top-align and supply
    /// their own padding) opt out by simply not calling this.
    func topAligned() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
    }
}
#endif
