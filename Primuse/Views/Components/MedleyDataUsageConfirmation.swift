import PrimuseKit
import SwiftUI

/// Asks before a medley starts on mobile data or Low Data Mode: to blend each
/// slice into the next it downloads the upcoming songs whole.
private struct MedleyDataUsageConfirmation: ViewModifier {
    @Binding var pendingSongs: [Song]?
    let start: ([Song]) -> Void

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "medley_data_title"),
            isPresented: Binding(
                get: { pendingSongs != nil },
                set: { if !$0 { pendingSongs = nil } }
            )
        ) {
            Button(String(localized: "medley_data_continue")) { confirm() }
            Button(String(localized: "medley_data_dont_ask")) {
                UserDefaults.standard.set(true, forKey: MedleyDataUsagePolicy.promptDisabledKey)
                confirm()
            }
            Button(String(localized: "cancel"), role: .cancel) { pendingSongs = nil }
        } message: {
            Text("medley_data_message")
        }
    }

    private func confirm() {
        guard let songs = pendingSongs else { return }
        pendingSongs = nil
        start(songs)
    }
}

extension View {
    /// Shows the mobile-data question while `pendingSongs` is set; `start`
    /// runs with them once the listener agrees.
    func medleyDataUsageConfirmation(
        pendingSongs: Binding<[Song]?>,
        start: @escaping ([Song]) -> Void
    ) -> some View {
        modifier(MedleyDataUsageConfirmation(pendingSongs: pendingSongs, start: start))
    }
}
