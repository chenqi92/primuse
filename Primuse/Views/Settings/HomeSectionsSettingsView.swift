import SwiftUI

/// Toggle which sections appear on Home. The Hero ("today's pick" /
/// library mix) is always shown — without it the page would just be
/// a tab title and a scroll hint, which makes the empty state
/// confusing. Other sections are independent.
///
/// Persistence is plain `@AppStorage`. Same keys as the Toggles in
/// `HomeView`, so changes here propagate live.
struct HomeSectionsSettingsView: View {
    @AppStorage("primuse.home.showStatsGlimpse") private var showStatsGlimpse: Bool = true
    @AppStorage("primuse.home.showForYou") private var showForYou: Bool = true
    @AppStorage("primuse.home.showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("primuse.home.showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("primuse.home.showContinueListening") private var showContinueListening: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showStatsGlimpse) {
                    Label("stats_title", systemImage: "chart.bar.xaxis")
                }
                Toggle(isOn: $showForYou) {
                    Label("home_section_for_you", systemImage: "sparkles")
                }
                Toggle(isOn: $showTopArtists) {
                    Label("home_section_top_artists", systemImage: "music.mic")
                }
                Toggle(isOn: $showRecentlyAdded) {
                    Label("home_section_recently_added", systemImage: "clock.badge.checkmark")
                }
                Toggle(isOn: $showContinueListening) {
                    Label("home_section_continue_listening", systemImage: "play.circle")
                }
            } header: {
                Text("home_settings_sections_label")
            } footer: {
                Text("home_settings_sections_footer")
            }
        }
        .navigationTitle("home_settings_title")
    }
}
