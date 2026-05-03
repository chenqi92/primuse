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
        case general, equalizer, effects, library, sources, widgets, sync, recentlyDeleted, security, about
    }

    @State private var tab: Tab = .general
    @State private var showLicenses = false

    var body: some View {
        TabView(selection: $tab) {
            PlaybackSettingsView().tabPaneSize()
                .tabItem { Label("playback_settings", systemImage: "play.circle") }
                .tag(Tab.general)

            EqualizerView().tabPaneSize().topAligned()
                .tabItem { Label("equalizer", systemImage: "slider.horizontal.3") }
                .tag(Tab.equalizer)

            AudioEffectsView().tabPaneSize()
                .tabItem { Label("audio_effects", systemImage: "waveform.badge.plus") }
                .tag(Tab.effects)

            MacMetadataScrapingView().tabPaneSize()
                .tabItem { Label("metadata_scraping", systemImage: "wand.and.stars") }
                .tag(Tab.library)

            MacSourcesView().tabPaneSize()
                .tabItem { Label("manage_sources", systemImage: "externaldrive.connected.to.line.below") }
                .tag(Tab.sources)

            MacWidgetSyncSettingsView().tabPaneSize()
                .tabItem { Label("desktop_widgets", systemImage: "rectangle.grid.2x2") }
                .tag(Tab.widgets)

            MacCloudSyncSettingsView().tabPaneSize()
                .tabItem { Label("icloud_sync_title", systemImage: "icloud") }
                .tag(Tab.sync)

            RecentlyDeletedView().tabPaneSize()
                .tabItem { Label("recently_deleted", systemImage: "trash") }
                .tag(Tab.recentlyDeleted)

            MacTrustedDomainsView().tabPaneSize()
                .tabItem { Label("trusted_domains", systemImage: "lock.shield") }
                .tag(Tab.security)

            aboutTab.tabPaneSize()
                .tabItem { Label("about", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var aboutTab: some View {
        Form {
            LabeledContent("version",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            LabeledContent("build",
                value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            // macOS Settings TabView 没有 NavigationStack — NavigationLink
            // 在这里点了完全没反应。改成弹 sheet,既能展示又符合 macOS 习惯。
            Button("licenses") { showLicenses = true }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLicenses) {
            NavigationStack {
                LicensesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { showLicenses = false }
                        }
                    }
            }
            .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
        }
    }
}

private struct MacWidgetSyncSettingsView: View {
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(MacWidgetSyncSettings.isEnabledKey) private var enabled: Bool = false
    @State private var showEnableExplanation = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        if newValue {
                            showEnableExplanation = true
                        } else {
                            enabled = false
                        }
                    }
                )) {
                    Label("desktop_widget_sync_enabled", systemImage: "rectangle.grid.2x2")
                }
                .toggleStyle(.switch)
            } footer: {
                Text("desktop_widget_sync_footer")
            }

            Section {
                LabeledContent {
                    Text(enabled ? "desktop_widget_sync_status_enabled" : "desktop_widget_sync_status_disabled")
                        .foregroundStyle(enabled ? .green : .secondary)
                } label: {
                    Text("status")
                }

                if enabled {
                    Button {
                        player.publishWidgetStateForMacWidgetSync()
                    } label: {
                        Label("desktop_widget_sync_update_now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } footer: {
                Text("desktop_widget_sync_privacy_footer")
            }
        }
        .formStyle(.grouped)
        .alert("desktop_widget_sync_explanation_title", isPresented: $showEnableExplanation) {
            Button("cancel", role: .cancel) {}
            Button("desktop_widget_sync_continue") {
                enabled = true
                player.publishWidgetStateForMacWidgetSync()
            }
        } message: {
            Text("desktop_widget_sync_explanation_message")
        }
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

    /// 给 Settings TabView 每个 tab 钉一个统一的 minSize,防止切到内容
    /// 少的 tab 时整个 NSWindow 突兀缩小。`alignment: .top` 关键 —
    /// 没有它的话短内容（例如关掉 Replay Gain 后的播放设置）会被
    /// SwiftUI 默认 center 在框里,远离顶部 tab toolbar,看起来非常空旷。
    /// 参考 Apple Music / System Settings 的做法,内容紧贴顶部。
    func tabPaneSize() -> some View {
        self.frame(minWidth: 720, minHeight: 520, alignment: .top)
    }
}
#endif
