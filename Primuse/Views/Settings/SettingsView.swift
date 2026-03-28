import SwiftUI
import PrimuseKit

struct SettingsView: View {
    @State private var cacheSize: String = "0 MB"
    @State private var showClearCacheAlert = false

    var body: some View {
        NavigationStack {
            List {
                Section("playback") {
                    NavigationLink {
                        EqualizerView()
                    } label: {
                        Label("equalizer", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("playback_settings", systemImage: "play.circle")
                    }

                    NavigationLink {
                        AudioOutputView()
                    } label: {
                        Label("audio_output", systemImage: "hifispeaker")
                    }
                }

                Section("library") {
                    HStack {
                        Label("cache_size", systemImage: "internaldrive")
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        Label("clear_cache", systemImage: "trash")
                    }

                    NavigationLink {
                        MetadataScrapingView()
                    } label: {
                        Label("metadata_scraping", systemImage: "wand.and.stars")
                    }
                }

                Section("about") {
                    HStack {
                        Text("version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("build")
                        Spacer()
                        Text("1")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        LicensesView()
                    } label: {
                        Text("licenses")
                    }
                }
            }
            .navigationTitle("settings_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .task {
                await refreshCacheSize()
            }
            .confirmationDialog("clear_cache_confirm", isPresented: $showClearCacheAlert) {
                Button("clear", role: .destructive) {
                    Task {
                        await clearCache()
                    }
                }
                Button("cancel", role: .cancel) {}
            }
        }
    }

    private func clearCache() async {
        await MetadataAssetStore.shared.clearAll()
        try? await ImageCache.shared.clearDiskCache()
        await refreshCacheSize()
    }

    private func refreshCacheSize() async {
        let imageCacheSize = (try? await ImageCache.shared.diskCacheSize()) ?? 0
        let metadataCacheSize = await MetadataAssetStore.shared.cacheSize()
        cacheSize = formatByteCount(imageCacheSize + metadataCacheSize)
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct MetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings

    var body: some View {
        @Bindable var settings = scraperSettings

        Form {
            Section("scraper_sources") {
                Toggle("musicbrainz_metadata", isOn: $settings.musicBrainzMetadataEnabled)
                Toggle("musicbrainz_cover", isOn: $settings.musicBrainzCoverEnabled)
                Toggle("lrclib_lyrics", isOn: $settings.lrclibLyricsEnabled)
                Toggle("only_fill_missing", isOn: $settings.onlyFillMissingFields)
            }

            Section {
                if scraperService.isScraping {
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
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        Button("cancel", role: .cancel) {
                            scraperService.cancel()
                        }
                    }
                } else {
                    Button("scrape_missing_metadata") {
                        scraperService.scrapeMissingMetadata(in: library)
                    }

                    Button("rescrape_library") {
                        scraperService.rescrapeLibrary(in: library)
                    }
                }
            } header: {
                Text("scrape_actions")
            } footer: {
                Text("scrape_description")
            }
        }
        .navigationTitle("metadata_scraping")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlaybackSettingsView: View {
    @State private var gaplessPlayback = true
    @State private var crossfade = false
    @State private var crossfadeDuration: Double = 3.0
    @State private var replayGain = false

    var body: some View {
        Form {
            Section("playback") {
                Toggle("gapless_playback", isOn: $gaplessPlayback)
                Toggle("crossfade", isOn: $crossfade)

                if crossfade {
                    VStack(alignment: .leading) {
                        Text("crossfade_duration")
                            .font(.caption)
                        Slider(value: $crossfadeDuration, in: 1...12, step: 1) {
                            Text("\(Int(crossfadeDuration))s")
                        }
                        Text("\(Int(crossfadeDuration)) \(String(localized: "seconds"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("replay_gain", isOn: $replayGain)
            }
        }
        .navigationTitle("playback_settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AudioOutputView: View {
    var body: some View {
        List {
            Section("current_output") {
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Text("iPhone Speaker")
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }

            Section {
                Text("audio_output_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("audio_output")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("open_source") {
                licenseRow("GRDB.swift", "MIT License")
                licenseRow("AMSMB2", "LGPL 2.1")
                licenseRow("FileProvider", "MIT License")
                licenseRow("FFmpeg", "LGPL 2.1")
            }
        }
        .navigationTitle("licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseRow(_ name: String, _ license: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
