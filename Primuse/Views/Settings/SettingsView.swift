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
                        LyricsTranslationSettingsView()
                    } label: {
                        Label("lyrics_translation_title", systemImage: "character.bubble")
                    }

                    NavigationLink {
                        DuplicateSongsView()
                    } label: {
                        Label("dup_title", systemImage: "square.stack.3d.up.badge.automatic")
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

                Section("appearance") {
                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        Label("app_icon", systemImage: "app.badge")
                    }
                }

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

                    NavigationLink {
                        ListeningStatsView()
                    } label: {
                        Label("stats_title", systemImage: "chart.bar.xaxis")
                    }

                    NavigationLink {
                        ScrobbleSettingsView()
                    } label: {
                        Label("scrobble_title", systemImage: "music.note.list")
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
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var shareTarget: ShareTarget?

    /// 分享 sheet 用 — URL 不是 Identifiable，包一层。
    struct ShareTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
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

                            Button {
                                if let url = makeShareableConfigFile(for: source) {
                                    shareTarget = ShareTarget(url: url)
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .tint(.green)
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
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
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
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
    }

    /// 把指定源的 ScraperConfig（含 secrets）写入临时文件返回 URL，供 ShareSheet 使用。
    /// 注意：分享出去的 JSON 包含 secrets，因此目标只能是用户私下分享（AirDrop / 信任的私人聊天）。
    private func makeShareableConfigFile(for source: ScraperSourceConfig) -> URL? {
        guard case .custom(let configId) = source.type,
              let config = ScraperConfigStore.shared.config(for: configId) else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ScraperConfig.encode(to:) 默认跳 secrets，先编出主体，再 inject secrets 拼成完整 bundle。
        guard let mainData = try? encoder.encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: mainData)) as? [String: Any] else { return nil }
        if let secrets = config.secrets, !secrets.isEmpty {
            dict["secrets"] = secrets
        }
        guard let bundleData = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        let safeId = configId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeId.isEmpty ? "scraper" : safeId).json")
        do {
            try bundleData.write(to: url, options: .atomic)
            return url
        } catch {
            plog("⚠️ Share scraper config: write temp file failed: \(error.localizedDescription)")
            return nil
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
    @Environment(MetadataBackfillService.self) private var backfill
    @AppStorage(MetadataBackfillService.wifiOnlyDefaultsKey) private var cloudScanWifiOnly: Bool = true
    @State private var audioCacheSize: String = "..."
    @State private var imageCacheSize: String = "..."
    @State private var metadataSize: String = "..."
    @State private var isClearingAudio = false
    @State private var isClearingImages = false
    @State private var isClearingMetadata = false
    @State private var audioBreakdown: SourceManager.AudioCacheBreakdown?
    @State private var isClearingPartials = false
    @State private var isClearingOrphans = false
    /// 清理结果提示 — 失败时让用户知道为什么没全清掉 (通常是当前正在播放的歌)。
    @State private var cacheActionToast: String?

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
                        let result = sourceManager.clearAudioCache()
                        await refreshSizes()
                        isClearingAudio = false
                        flashCacheToast(freed: result.freedBytes, failed: result.failedCount)
                    }
                }

                if let bd = audioBreakdown {
                    audioBreakdownDetail(bd)
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
        .overlay(alignment: .bottom) {
            if let msg = cacheActionToast {
                Text(msg)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func flashCacheToast(freed: Int64, failed: Int) {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let freedStr = fmt.string(fromByteCount: freed)
        let msg: String
        if failed > 0 {
            // 通常是当前正在播放的歌锁住了文件 — 提示一下用户暂停后重试
            msg = String(format: String(localized: "cache_clear_partial_format"), freedStr, failed)
        } else {
            msg = String(format: String(localized: "cache_clear_done_format"), freedStr)
        }
        withAnimation { cacheActionToast = msg }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { cacheActionToast = nil }
        }
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

    @ViewBuilder
    private func audioBreakdownDetail(_ bd: SourceManager.AudioCacheBreakdown) -> some View {
        let fmt = ByteCountFormatter()
        let _ = (fmt.countStyle = .file)

        // 缩进 + 小一号字, 提示是 audio cache 的细分
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary).font(.caption)
                Text("cache_completed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmt.string(fromByteCount: bd.completedBytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if bd.prewarmSeedBytes > 0 {
                HStack {
                    Image(systemName: "bolt.circle")
                        .foregroundStyle(.secondary).font(.caption)
                    Text("cache_prewarm_seed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.prewarmSeedBytes))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            HStack {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary).font(.caption)
                Text("cache_partial").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmt.string(fromByteCount: bd.partialBytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if bd.partialBytes > 0 {
                    Button(role: .destructive) {
                        isClearingPartials = true
                        Task {
                            let result = sourceManager.purgeAllPartialFiles()
                            await refreshSizes()
                            isClearingPartials = false
                            flashCacheToast(freed: result.freedBytes, failed: result.failedCount)
                        }
                    } label: {
                        if isClearingPartials {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "trash").font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isClearingPartials)
                }
            }

            if bd.orphanedBytes > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Text("cache_orphaned").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.orphanedBytes))
                        .font(.caption).foregroundStyle(.orange).monospacedDigit()
                    Button(role: .destructive) {
                        isClearingOrphans = true
                        Task {
                            await sourceManager.purgeOrphanedAudioCache()
                            await refreshSizes()
                            isClearingOrphans = false
                        }
                    } label: {
                        if isClearingOrphans {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "trash").font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isClearingOrphans)
                }
            }
        }
        .padding(.leading, 24)
    }

    private func refreshSizes() async {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let audio = Int64(sourceManager.audioCacheSize())
        audioCacheSize = formatter.string(fromByteCount: audio)
        audioBreakdown = await sourceManager.audioCacheBreakdown()

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


// MARK: - Share Sheet

/// SwiftUI 包装的 `UIActivityViewController`，让任意 view 通过 `.sheet`
/// 弹出系统分享面板（AirDrop / 微信 / 邮件 / 文件 / 等）。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
