import PrimuseKit
import SwiftUI

struct ArtistNameSettingsView: View {
    @State private var store = ArtistNameSettingsStore.shared
    @State private var newSeparator = ""
    @State private var newProtectedName = ""
    @State private var displaySeparatorDraft = ""
    @State private var showsResetConfirmation = false
    @AppStorage(GenreSplitPreference.storageKey) private var genreSeparatorsRaw = 0

    private func genreSeparatorBinding(_ option: GenreSeparatorOptions) -> Binding<Bool> {
        Binding(
            get: { GenreSeparatorOptions(rawValue: genreSeparatorsRaw).contains(option) },
            set: { isOn in
                var options = GenreSeparatorOptions(rawValue: genreSeparatorsRaw)
                if isOn { options.insert(option) } else { options.remove(option) }
                genreSeparatorsRaw = options.rawValue
            }
        )
    }

    private var preview: String {
        ArtistNameParser.displayName(
            rawName: "Artist A; Artist B",
            configuration: store.configuration
        ) ?? "Artist A; Artist B"
    }

    var body: some View {
        Form {
            if store.hasUnsupportedStoredConfiguration {
                Section {
                    Label("artist_name_settings_newer_version_warning", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent {
                    Text(preview)
                } label: {
                    SettingsInfoLabel("artist_name_settings_preview") {
                        Text("artist_name_settings_intro")
                    }
                }
            }

            Section {
                ForEach(Array(store.configuration.separators.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.body.monospaced())
                }
                .onDelete(perform: store.removeSeparators)

                HStack {
                    TextField("artist_name_settings_separator_placeholder", text: $newSeparator)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addSeparator)
                    Button("add", action: addSeparator)
                        .disabled(newSeparator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                SettingsInfoHeader("artist_name_settings_separators") {
                    Text("artist_name_settings_separators_footer")
                }
            }
            .settingsAnchor("artists.separators")

            Section {
                ForEach(Array(store.configuration.protectedNames.enumerated()), id: \.offset) { _, value in
                    Text(value)
                }
                .onDelete(perform: store.removeProtectedNames)

                HStack {
                    TextField("artist_name_settings_protected_placeholder", text: $newProtectedName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onSubmit(addProtectedName)
                    Button("add", action: addProtectedName)
                        .disabled(newProtectedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                SettingsInfoHeader("artist_name_settings_protected_names") {
                    Text("artist_name_settings_protected_footer")
                }
            }
            .settingsAnchor("artists.protectedNames")

            Section {
                HStack {
                    TextField(
                        "artist_name_settings_display_separator_placeholder",
                        text: $displaySeparatorDraft
                    )
                    .font(.body.monospaced())
                    .onSubmit(saveDisplaySeparator)

                    Button("save", action: saveDisplaySeparator)
                        .disabled(displaySeparatorDraft.isEmpty)
                }
            } header: {
                SettingsInfoHeader("artist_name_settings_display_separator") {
                    Text("artist_name_settings_display_footer")
                }
            }
            .settingsAnchor("artists.displaySeparator")

            Section {
                Toggle("artist_name_settings_merge_collaborative_albums", isOn: Binding(
                    get: { store.configuration.mergesCollaborativeAlbums },
                    set: { store.setMergesCollaborativeAlbums($0) }
                ))
            }
            .settingsAnchor("artists.mergeCollaborativeAlbums")

            Section {
                Toggle("genre_split_slash", isOn: genreSeparatorBinding(.slash))
                Toggle("genre_split_comma", isOn: genreSeparatorBinding(.comma))
                Toggle("genre_split_bar", isOn: genreSeparatorBinding(.bar))
            } header: {
                SettingsInfoHeader("genre_split_title") {
                    Text("genre_split_footer")
                }
            }
            .settingsAnchor("artists.genreSeparators")

            Section {
                Button("artist_name_settings_reset", role: .destructive) {
                    showsResetConfirmation = true
                }
                // 挂在触发按钮上，弹框从按钮长出来而不是贴在整页边缘。
                .confirmationDialog(
                    "artist_name_settings_reset_confirm",
                    isPresented: $showsResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("artist_name_settings_reset", role: .destructive) {
                        store.resetToDefaults()
                    }
                    Button("cancel", role: .cancel) {}
                }
            }
        }
        .navigationTitle("artist_name_settings_title")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .onAppear {
            displaySeparatorDraft = store.configuration.displaySeparator
        }
        .onChange(of: store.revision) {
            displaySeparatorDraft = store.configuration.displaySeparator
        }
    }

    private func addSeparator() {
        if store.addSeparator(newSeparator) {
            newSeparator = ""
        }
    }

    private func addProtectedName() {
        if store.addProtectedName(newProtectedName) {
            newProtectedName = ""
        }
    }

    private func saveDisplaySeparator() {
        guard !displaySeparatorDraft.isEmpty else { return }
        store.setDisplaySeparator(displaySeparatorDraft)
        displaySeparatorDraft = store.configuration.displaySeparator
    }
}
