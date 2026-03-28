import SwiftUI
import PrimuseKit

struct ScrapeOptionsView: View {
    let song: Song
    var onComplete: ((Song) -> Void)?

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(\.dismiss) private var dismiss

    @State private var scrapeMetadata = true
    @State private var scrapeCover = true
    @State private var scrapeLyrics = true
    @State private var isScraping = false
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // Current song info
                Section {
                    HStack(spacing: 12) {
                        CachedArtworkView(coverFileName: song.coverArtFileName, size: 56, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                            Text(song.artistName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(song.albumTitle ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }

                // What to scrape
                Section("scrape_options") {
                    Toggle("scrape_metadata_toggle", isOn: $scrapeMetadata)
                    Toggle("scrape_cover_toggle", isOn: $scrapeCover)
                    Toggle("scrape_lyrics_toggle", isOn: $scrapeLyrics)
                }

                // Sources info - dynamic from settings
                Section {
                    ForEach(scraperSettings.enabledSources) { source in
                        let isActive = isSourceActive(source)
                        HStack(spacing: 10) {
                            Image(systemName: source.type.iconName)
                                .font(.caption)
                                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                                .frame(width: 20)
                            Text(source.type.displayName)
                                .font(.subheadline)
                                .foregroundStyle(isActive ? .primary : .secondary)
                            Spacer()
                            capabilityBadges(for: source.type, active: isActive)
                        }
                    }
                } header: {
                    Text("scrape_sources_header")
                }

                // Result
                if let resultMessage {
                    Section {
                        Label(resultMessage, systemImage: resultMessage.contains("✓") ? "checkmark.circle" : "xmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(resultMessage.contains("✓") ? .green : .red)
                    }
                }
            }
            .navigationTitle("scrape_song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isScraping {
                        ProgressView()
                    } else {
                        Button("start_scrape") {
                            Task { await performScrape() }
                        }
                        .fontWeight(.semibold)
                        .disabled(!scrapeMetadata && !scrapeCover && !scrapeLyrics)
                    }
                }
            }
        }
    }

    private func isSourceActive(_ source: ScraperSourceConfig) -> Bool {
        (scrapeMetadata && source.type.supportsMetadata) ||
        (scrapeCover && source.type.supportsCover) ||
        (scrapeLyrics && source.type.supportsLyrics)
    }

    @ViewBuilder
    private func capabilityBadges(for type: MusicScraperType, active: Bool) -> some View {
        HStack(spacing: 4) {
            if type.supportsMetadata {
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundStyle(active && scrapeMetadata ? .primary : .tertiary)
            }
            if type.supportsCover {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(active && scrapeCover ? .primary : .tertiary)
            }
            if type.supportsLyrics {
                Image(systemName: "text.quote")
                    .font(.caption2)
                    .foregroundStyle(active && scrapeLyrics ? .primary : .tertiary)
            }
        }
    }

    private func performScrape() async {
        isScraping = true
        resultMessage = nil

        do {
            let updated = try await scraperService.scrapeSingle(song: song, in: library)
            isScraping = false

            var changes: [String] = []
            if updated.title != song.title || updated.artistName != song.artistName || updated.albumTitle != song.albumTitle {
                changes.append(String(localized: "metadata"))
            }
            if updated.coverArtFileName != song.coverArtFileName {
                changes.append(String(localized: "cover"))
            }
            if updated.lyricsFileName != song.lyricsFileName {
                changes.append(String(localized: "lyrics_word"))
            }

            if changes.isEmpty {
                resultMessage = String(localized: "scrape_no_changes")
            } else {
                resultMessage = "✓ " + changes.joined(separator: ", ")
            }

            onComplete?(updated)

            // Auto dismiss after short delay
            try? await Task.sleep(for: .seconds(1.5))
            dismiss()
        } catch {
            isScraping = false
            resultMessage = error.localizedDescription
        }
    }
}
