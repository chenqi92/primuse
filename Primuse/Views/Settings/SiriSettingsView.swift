#if os(iOS)
import AppIntents
import Intents
import SwiftUI
import UIKit

struct SiriSettingsView: View {
    @State private var authorizationStatus = SiriAuthorizationRuntime.status

    var body: some View {
        Form {
            Section {
                switch authorizationStatus {
                case .notDetermined:
                    Button {
                        requestAuthorization()
                    } label: {
                        statusRow
                    }
                    .buttonStyle(.plain)
                case .denied:
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        statusRow
                    }
                    .buttonStyle(.plain)
                case .restricted, .authorized:
                    statusRow
                @unknown default:
                    statusRow
                }
            } footer: {
                Text(usageDescription)
            }

            Section {
                SettingsShortcutsHelpView()
            }
            Section {
                Label("siri_play_song_example", systemImage: "quote.bubble")
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
            } header: {
                Text("siri_examples_title")
            } footer: {
                Text("siri_shortcuts_hint")
            }
            .settingsAnchor("siri.shortcuts")
        }
        .navigationTitle("Siri")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            authorizationStatus = SiriAuthorizationRuntime.status
        }
    }

    private var statusRow: some View {
        HStack {
            Label("Siri", systemImage: "waveform")
            Spacer()
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
        }
        .settingsAnchor("siri.authorization")
        .contentShape(Rectangle())
    }

    private var statusImage: String {
        switch authorizationStatus {
        case .authorized:
            return "checkmark.circle.fill"
        case .denied, .restricted:
            return "exclamationmark.circle.fill"
        case .notDetermined:
            return "circle"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch authorizationStatus {
        case .authorized:
            return .green
        case .denied, .restricted:
            return .orange
        case .notDetermined:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var usageDescription: String {
        Bundle.main.localizedInfoDictionary?["NSSiriUsageDescription"] as? String
            ?? Bundle.main.infoDictionary?["NSSiriUsageDescription"] as? String
            ?? "Siri"
    }

    private func requestAuthorization() {
        SiriAuthorizationRuntime.request { status in
            Task { @MainActor in
                authorizationStatus = status
            }
        }
    }
}
#endif
