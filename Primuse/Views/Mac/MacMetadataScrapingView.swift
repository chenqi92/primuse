#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native metadata scraping pane. Uses a real `List` for the scraper
/// sources so `.onMove` enables native drag-to-reorder, then drops the
/// options + scrape-actions blocks underneath as separate GroupBoxes.
struct MacMetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("metadata_scraping_desc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            sourcesList

            optionsBox
            actionsBox
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Sources (drag-to-reorder)

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("scraper_sources", systemImage: "wand.and.stars")
                .font(.headline)
                .padding(.horizontal, 4)

            List {
                ForEach(scraperSettings.sources) { source in
                    scraperRow(source: source)
                }
                .onMove { offsets, dest in
                    scraperSettings.reorderSources(fromOffsets: offsets, toOffset: dest)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)
            .scrollContentBackground(.hidden)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
    }

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
        .padding(.vertical, 2)
    }

    // MARK: - Options

    private var optionsBox: some View {
        @Bindable var settings = scraperSettings
        return GroupBox(label: Label("scraper_options", systemImage: "gearshape").font(.headline)) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("only_fill_missing", isOn: $settings.onlyFillMissingFields)
                Divider()
                HStack {
                    Text("reset_scraper_defaults")
                    Spacer()
                    Button(role: .destructive) {
                        scraperSettings.resetToDefaults()
                    } label: {
                        Text("reset")
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private var actionsBox: some View {
        GroupBox(label: Label("scrape_actions", systemImage: "arrow.triangle.2.circlepath").font(.headline)) {
            if scraperService.isScraping {
                scrapingProgress.padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("scrape_description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .padding(.vertical, 4)
            }
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
