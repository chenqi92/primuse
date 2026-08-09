#if os(iOS)
import Intents
import SwiftUI
import UIKit

struct SiriSettingsView: View {
    @State private var authorizationStatus = SiriAuthorizationRuntime.status

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Siri", systemImage: "waveform")
                    Spacer()
                    Image(systemName: statusImage)
                        .foregroundStyle(statusColor)
                }

                switch authorizationStatus {
                case .notDetermined:
                    Button {
                        requestAuthorization()
                    } label: {
                        Label("enable", systemImage: "checkmark.circle")
                    }
                case .denied:
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Label("settings_title", systemImage: "gear")
                    }
                case .restricted, .authorized:
                    EmptyView()
                @unknown default:
                    EmptyView()
                }
            } footer: {
                Text(usageDescription)
            }
        }
        .navigationTitle("Siri")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            authorizationStatus = SiriAuthorizationRuntime.status
        }
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
