import SwiftUI

/// The names Siri accepts for the app. They come from Info.plist (display name
/// plus `INAlternativeAppNames`) and are fixed when the app is built; nothing
/// at run time can add one, so the list is read back rather than repeated.
enum SiriSpokenAppNames {
    static func current(in bundle: Bundle = .main) -> [String] {
        let displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
        let alternatives = (bundle.infoDictionary?["INAlternativeAppNames"] as? [[String: Any]] ?? [])
            .compactMap { $0["INAlternativeAppName"] as? String }
        var seen = Set<String>()
        return ([displayName].compactMap { $0 } + alternatives).filter {
            !$0.isEmpty && seen.insert($0.lowercased()).inserted
        }
    }
}

struct SiriSpokenNamesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("siri_spoken_names_title")
                .font(.headline)
            Text(verbatim: SiriSpokenAppNames.current().joined(separator: " · "))
                .textSelection(.enabled)
            Text("siri_spoken_names_detail")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .settingsAnchor("siri.spokenNames")
    }
}

/// A personal shortcut is the only phrase a listener can choose: Siri runs it
/// by its name alone, so the app name never has to be heard correctly.
struct SiriCustomPhraseGuideView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("siri_custom_phrase_title")
                .font(.headline)
            step(1, "siri_custom_phrase_step_create")
            step(2, "siri_custom_phrase_step_action")
            step(3, "siri_custom_phrase_step_name")
            Text("siri_custom_phrase_footer")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: "shortcuts://create-shortcut") {
                    openURL(url)
                }
            } label: {
                Label("siri_custom_phrase_create", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
        }
        .settingsAnchor("siri.customPhrase")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
    }
}
