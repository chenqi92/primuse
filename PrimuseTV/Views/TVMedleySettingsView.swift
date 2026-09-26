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
                    ForEach(MedleySegmentPolicy.allowedSegmentLengths, id: \.self) { seconds in
                        TVPillButton(title: String(format: String(localized: "seconds_value_format"), seconds),
                                     systemImage: store.medleySegmentSeconds == seconds ? "checkmark.circle.fill" : "circle") {
                            store.setMedleySegmentSeconds(seconds)
                        }
                        .accessibilityIdentifier("tv.medley.seconds.\(seconds)")
                        .accessibilityAddTraits(store.medleySegmentSeconds == seconds ? .isSelected : [])
                    }
                }
                Text("medley_settings_footer").tvFont(.caption).foregroundStyle(TVColor.textMuted)
                Toggle("medley_data_prompt_toggle", isOn: Binding(get: { !promptDisabled }, set: { promptDisabled = !$0 }))
                    .padding(.top, 24)
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
        TVPillButton(title: String(localized: "medley_play_selection"), systemImage: "shuffle") {
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
