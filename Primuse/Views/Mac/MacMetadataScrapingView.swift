#if os(macOS)
import SwiftUI
import PrimuseKit
import AppKit

/// macOS-native metadata scraping pane. Wraps the same content as before in a
/// grouped Form so this tab matches the Apple-Music style of Playback /
/// Audio Effects / iCloud Sync — bold section headers, system row chrome,
/// helper text under each section. The drag-to-reorder list is embedded
/// inside its own Section so users can still reorder priorities.
struct MacMetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importError: String?
    @State private var importMode: ImportMode = .paste
    @State private var editingConfigSource: ScraperSourceConfig?
    @State private var editingConfigJSON = ""

    private enum ImportMode { case paste, url }

    var body: some View {
        @Bindable var settings = scraperSettings
        Form {
            Section {
                // List 不直接放在 Form 里(.onMove 在 grouped Form 里行为
                // 怪异),用 ForEach 直接渲染条目,拖动顺序用 .onMove。
                ForEach(scraperSettings.sources) { source in
                    scraperRow(source: source)
                }
                .onMove { offsets, dest in
                    scraperSettings.reorderSources(fromOffsets: offsets, toOffset: dest)
                }
            } header: {
                Text("scraper_sources")
            } footer: {
                Text("metadata_scraping_desc")
            }

            Section {
                Button {
                    importText = ""
                    importError = nil
                    importMode = .paste
                    showImportSheet = true
                } label: {
                    Label("import_scraper_source", systemImage: "square.and.arrow.down")
                }
            }

            Section {
                Toggle("only_fill_missing", isOn: $settings.onlyFillMissingFields)

                LabeledContent {
                    Button(role: .destructive) {
                        scraperSettings.resetToDefaults()
                    } label: {
                        Text("reset")
                    }
                } label: {
                    Text("reset_scraper_defaults")
                }
            } header: {
                Text("scraper_options")
            }

            Section {
                if scraperService.isScraping {
                    scrapingProgress
                } else {
                    HStack {
                        Button {
                            scraperService.scrapeMissingMetadata(in: library)
                        } label: {
                            Label("scrape_missing_metadata", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            scraperService.rescrapeLibrary(in: library)
                        } label: {
                            Label("rescrape_library", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                }
            } header: {
                Text("scrape_actions")
            } footer: {
                Text("scrape_description")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showImportSheet) {
            importScraperSheet
        }
        .sheet(item: $editingConfigSource) { source in
            editConfigSheet(source: source)
        }
    }

    // MARK: - Rows

    private func scraperRow(source: ScraperSourceConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Image(systemName: source.type.iconName)
                .font(.body)
                .foregroundStyle(source.isEnabled ? source.type.themeColor : .secondary)
                .frame(width: 22)
            Text(source.type.displayName)
                .font(.body)
            if source.type.supportsWordLevelLyrics {
                Text("lyrics_word_level_badge")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(source.type.themeColor.opacity(0.15))
                    )
                    .foregroundStyle(source.type.themeColor)
                    .accessibilityLabel(Text("lyrics_word_level_hint"))
            }
            Spacer()
            if case .custom(let configId) = source.type {
                Menu {
                    Button {
                        if let config = ScraperConfigStore.shared.config(for: configId),
                           let data = try? JSONEncoder.sortedPretty.encode(config),
                           let json = String(data: data, encoding: .utf8) {
                            editingConfigJSON = json
                            editingConfigSource = source
                        }
                    } label: {
                        Label("edit", systemImage: "pencil")
                    }

                    Button {
                        if let url = makeShareableConfigFile(for: source) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Label("export", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive) {
                        scraperSettings.removeCustomSource(id: source.id)
                    } label: {
                        Label("delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { _ in scraperSettings.toggleSource(id: source.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private var importScraperSheet: some View {
        NavigationStack {
            Form {
                Picker("import_mode", selection: $importMode) {
                    Text("paste_config").tag(ImportMode.paste)
                    Text("from_url").tag(ImportMode.url)
                }
                .pickerStyle(.segmented)

                Section {
                    if importMode == .paste {
                        TextEditor(text: $importText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 240)
                    } else {
                        TextField("config_url_placeholder", text: $importText)
                    }
                } footer: {
                    Text(LocalizedStringKey(importMode == .paste ? "paste_config_footer" : "url_config_footer"))
                }

                if let importError {
                    Section {
                        Text(importError)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("import_scraper_source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("import_action") { performImport() }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private func editConfigSheet(source: ScraperSourceConfig) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $editingConfigJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 340)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(source.type.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { editingConfigSource = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        do {
                            let configs = try ScraperConfigStore.shared.importFromJSON(editingConfigJSON)
                            guard configs.count == 1, let config = configs.first else { return }
                            scraperSettings.addCustomSource(config)
                            editingConfigSource = nil
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private func performImport() {
        importError = nil
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        if importMode == .url {
            guard let url = URL(string: text) else {
                importError = String(localized: "invalid_url")
                return
            }
            Task {
                do {
                    let configs = try await ScraperConfigStore.shared.importFromURL(url)
                    for config in configs { scraperSettings.addCustomSource(config) }
                    showImportSheet = false
                } catch {
                    importError = error.localizedDescription
                }
            }
        } else {
            do {
                let configs = try ScraperConfigStore.shared.importFromJSON(text)
                for config in configs { scraperSettings.addCustomSource(config) }
                showImportSheet = false
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func makeShareableConfigFile(for source: ScraperSourceConfig) -> URL? {
        guard case .custom(let configId) = source.type,
              let config = ScraperConfigStore.shared.config(for: configId),
              let data = exportData(for: config) else { return nil }
        let safeId = configId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeId.isEmpty ? "scraper" : safeId).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func exportData(for config: ScraperConfig) -> Data? {
        guard let mainData = try? JSONEncoder.sortedPretty.encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: mainData)) as? [String: Any] else {
            return nil
        }
        if let secrets = config.secrets, !secrets.isEmpty {
            dict["secrets"] = secrets
        }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    private var scrapingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: scraperService.progress)
            Text(scraperService.currentSongTitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 12) {
                Text("\(scraperService.processedCount)/\(scraperService.totalCount)")
                Text("·")
                Text("\(scraperService.updatedCount) \(String(localized: "updated_count"))")
                Text("·")
                Text("\(scraperService.failedCount) \(String(localized: "failed_count"))")
                Spacer()
                Button("cancel", role: .cancel) {
                    scraperService.cancel()
                }
                .controlSize(.small)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private extension JSONEncoder {
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
#endif
