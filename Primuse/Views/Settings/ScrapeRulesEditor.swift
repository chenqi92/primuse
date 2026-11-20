import SwiftUI
import PrimuseKit

struct ScrapeRulesEditor: View {
    @Bindable var settings: ScraperSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("only_fill_missing", isOn: $settings.onlyFillMissingFields)
                }
                Section {
                    ForEach(ScrapeField.allCases, id: \.self) { field in
                        NavigationLink {
                            fieldEditor(field)
                        } label: {
                            LabeledContent {
                                let rule = settings.fieldRules[field]
                                if let source = settings.sources.first(where: { $0.isEnabled && $0.type.rawValue == rule.preferredSource }),
                                   rule.mode != .skip {
                                    Text(verbatim: source.displayName)
                                }
                                Text(rule.mode.label)
                            } label: {
                                Text(field.label)
                            }
                        }
                        .accessibilityIdentifier("scraping.rule." + field.rawValue)
                    }
                }
                Section {
                    Menu("scrape_rules_all_fields") {
                        ForEach(ScrapeFieldMode.allCases, id: \.self) { mode in
                            Button(mode.label) {
                                var rules = settings.fieldRules
                                for field in ScrapeField.allCases { rules[field].mode = mode }
                                settings.fieldRules = rules
                            }
                        }
                    }
                }
            }
            .navigationTitle("scrape_field_rules")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func fieldEditor(_ field: ScrapeField) -> some View {
        let sources = settings.sources.filter { field.isSupported(by: $0.type) && $0.isEnabled }
        let preferredSource = Binding<String?>(
            get: { sources.first { $0.type.rawValue == settings.fieldRules[field].preferredSource }?.type.rawValue },
            set: { settings.fieldRules[field].preferredSource = $0 }
        )
        return Form {
            Section {
                Picker("scrape_field_rules", selection: $settings.fieldRules[field].mode) {
                    ForEach(ScrapeFieldMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.inline)
            }
            if settings.fieldRules[field].mode != .skip {
                Section {
                    Picker("scrape_preferred_source", selection: preferredSource) {
                        Text("scrape_source_order").tag(String?.none)
                        ForEach(sources) { source in
                            Text(verbatim: source.displayName).tag(Optional(source.type.rawValue))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
        .navigationTitle(field.label)
    }
}

extension ScrapeField {
    var label: LocalizedStringKey {
        switch self {
        case .title: "title"
        case .artist: "artist_label"
        case .album: "album_label"
        case .albumArtist: "album_metadata_album_artist"
        case .year: "year"
        case .track: "tag_editor_track"
        case .disc: "tag_editor_disc"
        case .genre: "genre"
        case .cover: "cover"
        case .lyrics: "lyrics_title"
        }
    }

    func isSupported(by type: MusicScraperType) -> Bool {
        switch self {
        case .cover: type.supportsCover
        case .lyrics: type.supportsLyrics
        default: type.supportsMetadata
        }
    }
}

private extension ScrapeFieldMode {
    var label: LocalizedStringKey {
        switch self {
        case .inherit: "ai_route_follow_default"
        case .skip: "skip"
        case .fillMissing: "scrape_rule_fill"
        case .overwrite: "scrape_rule_overwrite"
        }
    }
}
