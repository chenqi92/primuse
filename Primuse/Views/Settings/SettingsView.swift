import SwiftUI
import PrimuseKit

struct SettingsView: View {
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
                }

                Section("library") {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        Label("manage_sources", systemImage: "externaldrive.connected.to.line.below")
                    }

                    NavigationLink {
                        MetadataScrapingView()
                    } label: {
                        Label("metadata_scraping", systemImage: "wand.and.stars")
                    }

                    NavigationLink {
                        StorageManagementView()
                    } label: {
                        Label("storage_management", systemImage: "internaldrive")
                    }
                }

                Section("security") {
                    NavigationLink {
                        TrustedDomainsView()
                    } label: {
                        HStack {
                            Label("trusted_domains", systemImage: "lock.shield")
                            Spacer()
                            Text("\(SSLTrustStore.shared.trustedDomains.count)")
                                .foregroundStyle(.secondary)
                        }
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
        }
    }
}

struct MetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings

    @State private var editingCookieSourceId: String?
    @State private var cookieText = ""

    var body: some View {
        @Bindable var settings = scraperSettings

        Form {
            Section {
                ForEach(settings.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: source.type.iconName)
                            .font(.title3)
                            .foregroundStyle(source.isEnabled ? source.type.themeColor : .secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.type.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(source.type.localizedDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if source.type.supportsCookie {
                            Button {
                                editingCookieSourceId = source.id
                                cookieText = source.cookie ?? ""
                            } label: {
                                Image(systemName: "key")
                                    .font(.caption)
                                    .foregroundStyle(source.cookie?.isEmpty == false ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Toggle("", isOn: Binding(
                            get: { source.isEnabled },
                            set: { _ in scraperSettings.toggleSource(id: source.id) }
                        ))
                        .labelsHidden()
                    }
                }
                .onMove { scraperSettings.reorderSources(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("scraper_sources")
            } footer: {
                Text("scraper_sources_footer")
            }

            Section("scraper_options") {
                Toggle("only_fill_missing", isOn: $settings.onlyFillMissingFields)

                Button("reset_scraper_defaults") {
                    scraperSettings.resetToDefaults()
                }
                .foregroundStyle(.red)
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
        .environment(\.editMode, .constant(.active))
        .alert("cookie_config", isPresented: Binding(
            get: { editingCookieSourceId != nil },
            set: { if !$0 { editingCookieSourceId = nil } }
        )) {
            TextField("cookie_placeholder", text: $cookieText)
            Button("save") {
                if let id = editingCookieSourceId {
                    scraperSettings.updateCookie(id: id, cookie: cookieText.isEmpty ? nil : cookieText)
                }
                editingCookieSourceId = nil
            }
            Button("cancel", role: .cancel) {
                editingCookieSourceId = nil
            }
        } message: {
            Text("cookie_config_message")
        }
    }
}

struct PlaybackSettingsView: View {
    @Environment(PlaybackSettingsStore.self) private var playbackSettings

    var body: some View {
        @Bindable var settings = playbackSettings

        Form {
            Section {
                Toggle("gapless_playback", isOn: $settings.gaplessEnabled)
                    .disabled(true)
            } footer: {
                Text("gapless_not_available")
            }

            Section {
                Toggle("crossfade", isOn: $settings.crossfadeEnabled)

                if settings.crossfadeEnabled {
                    VStack(alignment: .leading) {
                        Text("crossfade_duration")
                            .font(.caption)
                        Slider(value: $settings.crossfadeDuration, in: 1...12, step: 1) {
                            Text("\(Int(settings.crossfadeDuration))s")
                        }
                        Text("\(Int(settings.crossfadeDuration)) \(String(localized: "seconds"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("crossfade_desc")
            }

            Section {
                Toggle("replay_gain", isOn: $settings.replayGainEnabled)

                if settings.replayGainEnabled {
                    Picker("rg_mode", selection: $settings.replayGainMode) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            } footer: {
                Text("replay_gain_desc")
            }

        }
        .navigationTitle("playback_settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage Management

struct StorageManagementView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @State private var audioCacheSize: String = "..."
    @State private var imageCacheSize: String = "..."
    @State private var metadataSize: String = "..."
    @State private var isClearingAudio = false
    @State private var isClearingImages = false
    @State private var isClearingMetadata = false

    var body: some View {
        @Bindable var settings = playbackSettings

        List {
            Section {
                Toggle("audio_cache_enabled", isOn: $settings.audioCacheEnabled)

                storageRow(
                    icon: "waveform",
                    title: "audio_cache",
                    size: audioCacheSize,
                    isClearing: isClearingAudio
                ) {
                    isClearingAudio = true
                    Task {
                        sourceManager.clearAudioCache()
                        await refreshSizes()
                        isClearingAudio = false
                    }
                }

                storageRow(
                    icon: "photo",
                    title: "image_cache",
                    size: imageCacheSize,
                    isClearing: isClearingImages
                ) {
                    isClearingImages = true
                    Task {
                        try? await ImageCache.shared.clearDiskCache()
                        CachedArtworkView.clearMemoryCache()
                        await refreshSizes()
                        isClearingImages = false
                    }
                }
            } header: {
                Text("cache")
            } footer: {
                Text("cache_clear_footer")
            }

            Section {
                storageRow(
                    icon: "music.note.list",
                    title: "cover_art_lyrics",
                    size: metadataSize,
                    isClearing: isClearingMetadata
                ) {
                    isClearingMetadata = true
                    Task {
                        await MetadataAssetStore.shared.clearAll()
                        CachedArtworkView.clearMemoryCache()
                        await refreshSizes()
                        isClearingMetadata = false
                    }
                }
            } header: {
                Text("persistent_data")
            } footer: {
                Text("metadata_clear_footer")
            }
        }
        .navigationTitle("storage_management")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSizes() }
    }

    private func storageRow(
        icon: String,
        title: LocalizedStringKey,
        size: String,
        isClearing: Bool,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if isClearing {
                ProgressView()
            } else {
                Text(size)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) { onClear() } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isClearing)
        }
    }

    private func refreshSizes() async {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let audio = Int64(sourceManager.audioCacheSize())
        audioCacheSize = formatter.string(fromByteCount: audio)

        let images = (try? await ImageCache.shared.diskCacheSize()) ?? 0
        imageCacheSize = formatter.string(fromByteCount: images)

        let metadata = await MetadataAssetStore.shared.cacheSize()
        metadataSize = formatter.string(fromByteCount: metadata)
    }
}

// MARK: - Trusted Domains

struct TrustedDomainsView: View {
    @State private var newDomain = ""
    @State private var showAddAlert = false

    var body: some View {
        List {
            Section {
                ForEach(SSLTrustStore.shared.trustedDomains, id: \.self) { domain in
                    Text(domain)
                }
                .onDelete { indexSet in
                    let domains = SSLTrustStore.shared.trustedDomains
                    for index in indexSet {
                        SSLTrustStore.shared.untrust(domain: domains[index])
                    }
                }

                if SSLTrustStore.shared.trustedDomains.isEmpty {
                    Text("no_trusted_domains")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("trusted_domains_footer")
            }
        }
        .navigationTitle("trusted_domains")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newDomain = ""
                    showAddAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("add_trusted_domain", isPresented: $showAddAlert) {
            TextField("domain_placeholder", text: $newDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("add") {
                let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !domain.isEmpty {
                    SSLTrustStore.shared.trust(domain: domain)
                }
                newDomain = ""
            }
            Button("cancel", role: .cancel) { newDomain = "" }
        } message: {
            Text("add_trusted_domain_message")
        }
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("open_source") {
                licenseRow("SFBAudioEngine", "MIT License")
                licenseRow("GRDB.swift", "MIT License")
                licenseRow("AMSMB2", "LGPL 2.1")
                licenseRow("FileProvider", "MIT License")
                licenseRow("FLAC", "BSD License")
                licenseRow("mpg123", "LGPL 2.1")
                licenseRow("libsndfile", "LGPL 2.1")
                licenseRow("libogg / libvorbis", "BSD License")
                licenseRow("libopus", "BSD License")
                licenseRow("WavPack", "BSD License")
                licenseRow("Monkey's Audio", "BSD License")
                licenseRow("True Audio (libtta)", "LGPL 2.1")
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
