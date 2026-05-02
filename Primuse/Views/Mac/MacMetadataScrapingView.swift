#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native metadata scraping pane. Wraps the same content as before in a
/// grouped Form so this tab matches the Apple-Music style of Playback /
/// Audio Effects / iCloud Sync — bold section headers, system row chrome,
/// helper text under each section. The drag-to-reorder list is embedded
/// inside its own Section so users can still reorder priorities.
struct MacMetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings

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
            Spacer()
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { _ in scraperSettings.toggleSource(id: source.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
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
#endif
