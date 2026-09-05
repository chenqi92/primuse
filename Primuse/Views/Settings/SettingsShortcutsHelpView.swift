import AppIntents
import SwiftUI

struct SettingsShortcutsHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsStrings.text("Use Siri to open settings, or combine setting actions in Shortcuts."))
                .foregroundStyle(.secondary)
            help("Open Setting", "Open a setting by name. No preference is changed.", icon: "arrow.up.forward.app")
            help("Get Setting", "Read the current value and any restrictions.", icon: "info.circle")
            help("Set Setting", "Choose a setting and an explicit on or off value.", icon: "switch.2")
            help("Set Audio Output Mode", "Choose High Fidelity or audio effects. Playback Speed is also available in Shortcuts.", icon: "waveform")

            DisclosureGroup(SettingsStrings.text("Settings you can change")) {
                ForEach(SettingsCatalog.available.filter { SettingsActionService.toggleIDs.contains($0.id) }) { item in
                    Button {
                        SettingsNavigation.shared.open(item.id)
                    } label: {
                        HStack {
                            Text(verbatim: item.title)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(SettingsStrings.text("Account authorization, sharing, deletion, and bulk changes are completed in the app with their existing confirmations."))
                .font(.callout)
                .foregroundStyle(.secondary)
            #if os(macOS)
            Link(SettingsStrings.text("Open Shortcuts"), destination: URL(string: "shortcuts://")!)
            #endif
        }
    }

    private func help(_ title: String, _ detail: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsStrings.text(title)).font(.headline)
                Text(SettingsStrings.text(detail)).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 24)
        }
    }
}
