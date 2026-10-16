#if os(tvOS)
import SwiftUI
import Network
import PrimuseKit

@MainActor
@Observable
final class TVMedleyNetworkState {
    static let shared = TVMedleyNetworkState()
    private let monitor = NWPathMonitor()
    var isMetered = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in self?.isMetered = metered }
        }
        monitor.start(queue: DispatchQueue(label: "primuse.tv.medley.network"))
    }
}

struct TVMedleySettingsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MedleyDataUsagePolicy.promptDisabledKey) private var promptDisabled = false

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Text("medley_title").tvFont(.pageTitle)
                Text("medley_segment_length").tvFont(.rowTitle)
                HStack(spacing: 22) {
                    ForEach(MedleySegmentPolicy.segmentChoices, id: \.self) { choice in
                        let isSelected = store.medleySegmentChoice == choice
                        TVPillButton(title: choice == MedleySegmentPolicy.automaticSegmentChoice
                                        ? String(localized: "medley_segment_automatic")
                                        : String(format: String(localized: "seconds_value_format"), choice),
                                     systemImage: isSelected ? "checkmark.circle.fill" : "circle") {
                            store.setMedleySegmentChoice(choice)
                        }
                        .accessibilityIdentifier(choice == MedleySegmentPolicy.automaticSegmentChoice
                                                    ? "tv.medley.seconds.auto" : "tv.medley.seconds.\(choice)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                Text("medley_settings_footer").tvFont(.caption).foregroundStyle(TVColor.textMuted)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("medley_prefers_playback_range", isOn: Binding(
                        get: { store.medleyPrefersPlaybackRange },
                        set: { store.setMedleyPrefersPlaybackRange($0) }
                    ))
                    .accessibilityIdentifier("tv.medley.prefersPlaybackRange")
                    Text("medley_prefers_playback_range_hint").tvFont(.caption).foregroundStyle(TVColor.textMuted)
                }
                .padding(.top, 24)
                Toggle("medley_data_prompt_toggle", isOn: Binding(get: { !promptDisabled }, set: { promptDisabled = !$0 }))
            }
            .foregroundStyle(TVColor.text)
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(70)
        }
        .onExitCommand { dismiss() }
    }
}

struct TVMedleyButton: View {
    @Environment(TVStore.self) private var store
    let songIDs: [String]
    var onStarted: () -> Void = {}
    @State private var pendingIDs: [String]?

    var body: some View {
        TVPillButton(title: String(localized: "medley_play_selection"), systemImage: "rectangle.stack.badge.play") {
            pendingIDs = songIDs
        }
        .disabled(!store.canPlayMedley(songIDs: songIDs))
        .accessibilityIdentifier("tv.medley.start")
        .modifier(TVMedleyConfirmation(pendingIDs: $pendingIDs, onStarted: onStarted))
    }
}

struct TVMedleyConfirmation: ViewModifier {
    @Environment(TVStore.self) private var store
    @Binding var pendingIDs: [String]?
    var onStarted: () -> Void = {}
    @State private var showsConfirmation = false

    func body(content: Content) -> some View {
        content
            .onAppear { _ = TVMedleyNetworkState.shared }
            .onChange(of: pendingIDs) { _, ids in
                guard let ids else { return }
                if store.medleyNeedsDataUsageConfirmation(songIDs: ids) { showsConfirmation = true }
                else { start() }
            }
            .confirmationDialog("medley_data_title", isPresented: $showsConfirmation, titleVisibility: .visible) {
                Button("medley_data_continue") { start() }
                Button("medley_data_dont_ask") {
                    UserDefaults.standard.set(true, forKey: MedleyDataUsagePolicy.promptDisabledKey)
                    start()
                }
                Button("cancel", role: .cancel) { pendingIDs = nil }
            } message: { Text("medley_data_message") }
    }

    private func start() {
        guard let ids = pendingIDs else { return }
        pendingIDs = nil
        if store.playMedley(songIDs: ids) { onStarted() }
    }
}
#endif
