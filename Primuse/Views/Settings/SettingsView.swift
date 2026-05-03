import SwiftUI
import PrimuseKit

struct SettingsView: View {
    @AppStorage(UserNotificationService.notifyLongTasksKey) private var notifyLongTasks: Bool = true

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
                        AudioEffectsView()
                    } label: {
                        Label("audio_effects", systemImage: "waveform.badge.plus")
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

                #if os(iOS)
                Section("appearance") {
                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        Label("app_icon", systemImage: "app.badge")
                    }
                }
                #endif

                Section("sync") {
                    NavigationLink {
                        CloudSyncSettingsView()
                    } label: {
                        Label("icloud_sync_title", systemImage: "icloud")
                    }

                    NavigationLink {
                        RecentlyDeletedView()
                    } label: {
                        Label("recently_deleted", systemImage: "trash")
                    }
                }

                Section {
                    Toggle("notify_long_tasks", isOn: $notifyLongTasks)
                    Text("notify_long_tasks_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("about") {
                    HStack {
                        Text("version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
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
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importError: String?
    @State private var importMode: ImportMode = .paste
    @State private var editingConfigSource: ScraperSourceConfig?
    @State private var editingConfigJSON = ""
    @State private var isReordering = false

    enum ImportMode { case paste, url }

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

                        Text(source.type.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)

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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !source.type.isBuiltIn {
                            Button(role: .destructive) {
                                scraperSettings.removeCustomSource(id: source.id)
                            } label: {
                                Image(systemName: "trash")
                            }

                            Button {
                                if case .custom(let configId) = source.type,
                                   let config = ScraperConfigStore.shared.config(for: configId) {
                                    let encoder = JSONEncoder()
                                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                    if let data = try? encoder.encode(config),
                                       let json = String(data: data, encoding: .utf8) {
                                        editingConfigJSON = json
                                        editingConfigSource = source
                                    }
                                }
                            } label: {
                                Image(systemName: "doc.text")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .onMove { scraperSettings.reorderSources(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    Text("scraper_sources")
                    Spacer()
                    Button(isReordering ? String(localized: "done") : String(localized: "reorder")) {
                        withAnimation { isReordering.toggle() }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }

            Section {
                Button {
                    importText = ""
                    importError = nil
                    showImportSheet = true
                } label: {
                    Label("import_scraper_source", systemImage: "plus.circle")
                }
            } header: {
                Text("custom_sources")
            } footer: {
                Text("import_scraper_footer")
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
                        .buttonStyle(.borderless)
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
        #if os(iOS)
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        #endif
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
        .sheet(isPresented: $showImportSheet) {
            importScraperSheet
        }
        .sheet(item: $editingConfigSource) { source in
            editConfigSheet(source: source)
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
                            .frame(minHeight: 200)
                    } else {
                        TextField("config_url_placeholder", text: $importText)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                    }
                } footer: {
                    if importMode == .paste {
                        Text("paste_config_footer")
                    } else {
                        Text("url_config_footer")
                    }
                }

                if let error = importError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("import_scraper_source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("import_action") {
                        performImport()
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func editConfigSheet(source: ScraperSourceConfig) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $editingConfigJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 300)
                }
            }
            .navigationTitle(source.type.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { editingConfigSource = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        do {
                            let configs = try ScraperConfigStore.shared.importFromJSON(editingConfigJSON)
                            guard configs.count == 1, let config = configs.first else {
                                plog("Config save error: edit accepts a single source only, got \(configs.count)")
                                return
                            }
                            scraperSettings.addCustomSource(config)
                            editingConfigSource = nil
                        } catch {
                            plog("Config save error: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func performImport() {
        importError = nil
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        plog("📥 Import: mode=\(importMode == .url ? "url" : "paste") textLen=\(text.count)")

        if importMode == .url {
            guard let url = URL(string: text) else {
                importError = String(localized: "invalid_url")
                return
            }
            Task {
                do {
                    let configs = try await ScraperConfigStore.shared.importFromURL(url)
                    plog("📥 Import success (url): count=\(configs.count) ids=\(configs.map(\.id))")
                    for config in configs { scraperSettings.addCustomSource(config) }
                    showImportSheet = false
                } catch {
                    importError = error.localizedDescription
                }
            }
        } else {
            do {
                let configs = try ScraperConfigStore.shared.importFromJSON(text)
                plog("📥 Import success: count=\(configs.count) ids=\(configs.map(\.id))")
                for config in configs { scraperSettings.addCustomSource(config) }
                showImportSheet = false
            } catch {
                plog("📥 Import failed: \(error.localizedDescription)")
                importError = error.localizedDescription
            }
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
                    // 之前 Slider 的 trailing label "3s" 和下方 caption2 "3 秒"
                    // 同时显示,在 macOS Form 里产生左右各一处重复的当前值。
                    // 改为「title 左 / 当前值右」一行 + slider 单独一行,只显示一次值。
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("crossfade_duration")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(settings.crossfadeDuration)) \(String(localized: "seconds"))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.crossfadeDuration, in: 1...12, step: 1)
                    }
                }
            } footer: {
                Text("crossfade_desc")
            }

            Section {
                Toggle("replay_gain", isOn: $settings.replayGainEnabled)

                if settings.replayGainEnabled {
                    // 用 LabeledContent 显式分隔 title / Picker, 这样 macOS Form
                    // 才会把 dropdown 推到行尾, 不会"模式 单曲"挤在最左留一片空白。
                    LabeledContent {
                        Picker("", selection: $settings.replayGainMode) {
                            ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } label: {
                        Text("rg_mode")
                    }
                }
            } footer: {
                Text("replay_gain_desc")
            }

        }
        #if os(macOS)
        // macOS Settings 已经把 tab 标题画在窗口顶部,navigationTitle 在
        // 这里既看不见也会让 SwiftUI 警告。Form 用 grouped 样式才像
        // System Settings,跟 EqualizerView / AudioEffectsView 保持一致。
        .formStyle(.grouped)
        #else
        .navigationTitle("playback_settings")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Storage Management

struct StorageManagementView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(MetadataBackfillService.self) private var backfill
    @AppStorage(MetadataBackfillService.wifiOnlyDefaultsKey) private var cloudScanWifiOnly: Bool = true
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
                Toggle("cloud_scan_wifi_only", isOn: $cloudScanWifiOnly)
                    .onChange(of: cloudScanWifiOnly) { _, _ in
                        // Re-evaluate immediately so the user sees backfill
                        // start (or stop) right after flipping the switch.
                        backfill.refreshQueue()
                    }
                if backfill.hasPendingWork {
                    HStack {
                        Text("backfill_in_progress")
                        Spacer()
                        Text(String(format: String(localized: "backfill_remaining"), backfill.remainingCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("network")
            } footer: {
                Text("cloud_scan_wifi_only_footer")
            }

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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
