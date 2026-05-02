#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native metadata scraping pane. Replaces the iOS list-with-swipe
/// design with GroupBox sections, native Toggle/Button controls and a
/// proper progress block. Handles the 95% common case (toggle scrapers /
/// run scrape / reset). Importing custom JSON scraper configs and
/// per-source cookie editing remain in the iOS-side advanced view for now.
struct MacMetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings

    var body: some View {
        @Bindable var settings = scraperSettings

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                Text("metadata_scraping_desc")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                GroupBox(label: groupLabel("scraper_sources", systemImage: "wand.and.stars")) {
                    VStack(spacing: 0) {
                        ForEach(Array(settings.sources.enumerated()), id: \.element.id) { index, source in
                            scraperRow(source: source)
                            if index < settings.sources.count - 1 {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox(label: groupLabel("scraper_options", systemImage: "gearshape")) {
                    VStack(alignment: .leading, spacing: 12) {
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

                GroupBox(label: groupLabel("scrape_actions", systemImage: "arrow.triangle.2.circlepath")) {
                    if scraperService.isScraping {
                        scrapingProgress
                            .padding(.vertical, 6)
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
            .padding(20)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func groupLabel(_ key: LocalizedStringKey, systemImage: String) -> some View {
        Label(key, systemImage: systemImage)
            .font(.headline)
    }

    private func scraperRow(source: ScraperSourceConfig) -> some View {
        HStack(spacing: 12) {
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
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private var scrapingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: scraperService.progress)
            Text(scraperService.currentSongTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
#endif
