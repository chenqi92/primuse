import CloudKit
import SwiftUI
import PrimuseKit
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
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
                        PlaylistImportView()
                    } label: {
                        Label("playlist_import_title", systemImage: "tray.and.arrow.down")
                    }

                    NavigationLink {
                        StorageManagementView()
                    } label: {
                        Label("storage_management", systemImage: "internaldrive")
                    }
                }

                Section("sync") {
                    NavigationLink {
                        CloudSyncSettingsView()
                    } label: {
                        Label("icloud_sync_title", systemImage: "icloud")
                    }

                    NavigationLink {
                        FamilySharingSettingsView()
                    } label: {
                        Label("family_sharing_title", systemImage: "person.2.fill")
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

                    NavigationLink {
                        AppleMusicSettingsView()
                    } label: {
                        Label("settings_apple_music_section", systemImage: "applelogo")
                    }

                    NavigationLink {
                        DLNARendererSettingsView()
                    } label: {
                        Label("settings_dlna_section", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section {
                    AppleTVPushRow()

                    NavigationLink {
                        RelaySettingsView()
                    } label: {
                        Label("settings_relay_section", systemImage: "appletv")
                    }
                } header: {
                    Text("settings_appletv_section")
                }

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
                    #if os(iOS)
                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        Label("app_icon", systemImage: "app.badge")
                    }
                    #endif

                    NavigationLink {
                        HomeSectionsSettingsView()
                    } label: {
                        Label("home_settings_title", systemImage: "house")
                    }
                }

                Section("about") {
                    HStack {
                        Label("version", systemImage: "number")
                        Spacer()
                        Text(Bundle.main.appVersion)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("build", systemImage: "hammer")
                        Spacer()
                        Text(Bundle.main.appBuildNumber)
                            .foregroundStyle(.secondary)
                    }

                    CheckForUpdateRow()

                    NavigationLink {
                        DiagnosticReportsView(service: AppServices.shared.crashDiagnostics)
                    } label: {
                        Label(String(localized: "diagnostics_title"), systemImage: "stethoscope")
                    }

                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("licenses", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("settings_title")
            .toolbarTitleDisplayMode(.inlineLarge)
        }
    }
}

/// Settings row that lets the user manually poll the App Store. Three
/// visual states:
/// - Idle: tappable "Check for updates" row.
/// - Checking: spinner replaces the chevron.
/// - Result: inline status line under the title — "you're on the
///   latest version" or "version X.Y.Z available, tap to update".
private struct CheckForUpdateRow: View {
    @Environment(AppUpdateChecker.self) private var checker

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
    }

    @State private var status: Status = .idle

    var body: some View {
        Button {
            switch status {
            case .available:
                checker.openAppStore()
            case .idle, .upToDate:
                Task { await runCheck() }
            case .checking:
                break
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("check_for_updates")
                            .foregroundStyle(.primary)
                        if let detail = statusDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Spacer()
                accessory
            }
        }
        .buttonStyle(.plain)
        .disabled(status == .checking)
    }

    @ViewBuilder
    private var accessory: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.tint)
        default:
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusDetail: String? {
        switch status {
        case .idle, .checking:
            return nil
        case .upToDate:
            return String(localized: "check_for_updates_up_to_date")
        case .available(let v):
            return String(format: String(localized: "check_for_updates_available_format"), v)
        }
    }

    private var statusColor: Color {
        switch status {
        case .available: return .accentColor
        default: return .secondary
        }
    }

    private func runCheck() async {
        status = .checking
        // force=true bypasses the 6h throttle so the manual button
        // always actually hits the network.
        await checker.checkForUpdate(force: true)
        if let info = checker.availableUpdate {
            status = .available(version: info.version)
        } else {
            status = .upToDate
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
        #if os(iOS)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
            #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
            #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                    .onChange(of: settings.gaplessEnabled) { _, enabled in
                        if enabled { settings.crossfadeEnabled = false }
                    }
            } footer: {
                Text("gapless_desc")
            }

            Section {
                Toggle("crossfade", isOn: $settings.crossfadeEnabled)
                    .onChange(of: settings.crossfadeEnabled) { _, enabled in
                        if enabled { settings.gaplessEnabled = false }
                    }

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

            Section {
                Toggle("spatial_audio", isOn: $settings.spatialAudioEnabled)

                if settings.spatialAudioEnabled {
                    Toggle("spatial_head_tracking", isOn: $settings.spatialHeadTrackingEnabled)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("spatial_audio_desc")
                    if settings.spatialAudioEnabled {
                        Text("spatial_head_tracking_desc")
                    }
                }
            }

            Section {
                HStack {
                    Text("playback_rate")
                    Spacer()
                    Text(String(format: "%.2fx", settings.playbackRate))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $settings.playbackRate,
                    in: 0.5...2.0,
                    step: 0.05
                ) {
                    Text("playback_rate")
                } minimumValueLabel: {
                    Text("0.5x").font(.caption2)
                } maximumValueLabel: {
                    Text("2.0x").font(.caption2)
                }
                if settings.playbackRate != 1.0 {
                    Button("playback_rate_reset") {
                        settings.playbackRate = 1.0
                    }
                    .font(.caption)
                }
            } header: {
                Text("playback_rate_section")
            } footer: {
                Text("playback_rate_desc")
            }

            Section {
                Toggle("output_sr_matching", isOn: $settings.matchOutputSampleRate)
            } footer: {
                Text("output_sr_matching_desc")
            }

        }
        .navigationTitle("playback_settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Send to Apple TV

/// 一键把当前曲库 + 音乐源 + 凭据(含中继端点)立刻上传到 iCloud,供 Apple TV 拉取。
/// 平时退后台也会自动上传;这个按钮是「立即、可见」的显式入口。
private struct AppleTVPushRow: View {
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @Environment(MusicLibrary.self) private var musicLibrary
    @State private var pushing = false
    @State private var result: Bool?   // nil=空闲, true=已推送, false=失败

    var body: some View {
        Button {
            guard !pushing else { return }
            pushing = true; result = nil
            // 先把最新曲库落盘成快照,否则 uploadNow 会因本地没有 library-cache.json 直接跳过(按钮看似没反应)。
            musicLibrary.persistNow()
            Task {
                let ok = await LibrarySnapshotSync.shared.uploadNow()
                pushing = false; result = ok
                try? await Task.sleep(for: .seconds(4))
                result = nil
            }
        } label: {
            HStack {
                Label("settings_push_to_tv", systemImage: "appletv.fill")
                Spacer()
                if pushing {
                    ProgressView()
                } else if let result {
                    Label(result ? "settings_push_to_tv_done" : "settings_push_to_tv_failed",
                          systemImage: result ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(result ? .green : .orange)
                }
            }
        }
        .disabled(pushing || !iCloudSyncEnabled)
    }
}

// MARK: - Apple TV Relay

/// Phase 3:Apple TV 局域网中继开关。开启后,登录同一 Apple ID 的 Apple TV
/// 可经本机中继播放本地 / SMB / SFTP / NFS / WebDAV 等无法直连的源。
///
/// 开关持久化用 @AppStorage(`phoneRelayEnabled`,与 PhoneRelayServer 守卫的
/// key 同一个),实际生效靠 onChange 调 server.start/stop;app 启动时
/// AppServices 已按这个 key 自动拉起,所以无需在此恢复状态。
/// 变更后顺手把凭据包(含中继端点)推到 iCloud,让 TV 尽快拿到 / 失效。
struct RelaySettingsView: View {
    @AppStorage(PhoneRelayServer.enabledKey) private var enabled: Bool = false
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @State private var endpoint: RelayEndpoint?

    var body: some View {
        Form {
            Section {
                Text(String(localized: "settings_push_to_tv_footer"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "settings_relay_enable"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { startRelay() } else { PhoneRelayServer.shared.stop() }
                        pushCredentialsToTV(relayOn: on)
                    }

                if enabled {
                    if let endpoint {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                            Text(verbatim: "\(endpoint.host):\(endpoint.port)")
                                .font(.subheadline.monospacedDigit())
                                .textSelection(.enabled)
                        }
                    } else {
                        HStack {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.orange)
                            Text(String(localized: "settings_relay_waiting"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text(String(localized: "settings_relay_footer"))
                    .font(.footnote)
            }
        }
        .navigationTitle("settings_relay_section")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 进页面 / 开关翻动后刷新端点显示。端口绑定是异步的,开启时轮询几次再读。
        .task(id: enabled) {
            endpoint = enabled ? await waitForEndpoint() : nil
        }
    }

    private func startRelay() {
        let services = AppServices.shared
        PhoneRelayServer.shared.startIfEnabled(
            sourceManager: services.sourceManager,
            sourcesStore: services.sourcesStore,
            library: services.musicLibrary
        )
    }

    /// 把凭据包(含中继端点)覆盖上传到 iCloud。开启时监听端口要等几十毫秒才
    /// ready,先等 endpoint 就绪再传,确保端点进包;关闭时立即传,让 TV 端失效。
    private func pushCredentialsToTV(relayOn: Bool) {
        guard iCloudSyncEnabled else { return }   // iCloud 同步关闭时不上传(中继端点也无从下发)
        Task {
            if relayOn { _ = await waitForEndpoint() }
            await LibrarySnapshotSync.shared.uploadNow()
        }
    }

    /// 轮询直到监听端口绑定好(或 ~1.8s 超时)。未连 Wi-Fi 时始终 nil。
    private func waitForEndpoint() async -> RelayEndpoint? {
        for _ in 0..<12 {
            if let ep = PhoneRelayServer.shared.endpoint() { return ep }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return PhoneRelayServer.shared.endpoint()
    }
}

// MARK: - Storage Management

struct StorageManagementView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(MetadataBackfillService.self) private var backfill
    @AppStorage(MetadataBackfillService.wifiOnlyDefaultsKey) private var cloudScanWifiOnly: Bool = true
    @AppStorage(UserNotificationService.notifyLongTasksKey) private var notifyBackfillComplete: Bool = false
    /// 系统授权状态 ── 进页面时查一次。用户在系统 Settings 关掉后, toggle
    /// 仍是 on 但显示"已被系统拒绝"提示, 让用户知道为什么开关无效。
    @State private var notificationStatusDenied: Bool = false
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
    @State private var logShareItem: LogShareItem?

    struct LogShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

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
                Toggle("notify_backfill_complete", isOn: $notifyBackfillComplete)
                    .onChange(of: notifyBackfillComplete) { _, on in
                        guard on else { return }
                        // 用户从关 → 开: 主动请求权限。UserNotificationService 内部
                        // 会 lazy 请求, 这里直接发一条 silent 'probe' 触发授权
                        // 弹窗即可; 之前 deny 过的话不会再弹, 我们改用直接查询
                        // UNUserNotificationCenter.notificationSettings() 检测。
                        Task {
                            let center = UNUserNotificationCenter.current()
                            let settings = await center.notificationSettings()
                            if settings.authorizationStatus == .notDetermined {
                                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                                if !granted {
                                    notificationStatusDenied = true
                                }
                            } else if settings.authorizationStatus == .denied {
                                notificationStatusDenied = true
                            }
                        }
                    }
                if notifyBackfillComplete && notificationStatusDenied {
                    Label("notify_permission_denied_hint", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
            .task {
                // 进设置页时查一次系统授权状态。如果用户在 Settings 关掉了,
                // toggle 显示打开但 notificationStatusDenied 让 UI 提示。
                if notifyBackfillComplete {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    notificationStatusDenied = (settings.authorizationStatus == .denied)
                }
            }

            Section {
                Toggle("audio_cache_enabled", isOn: $settings.audioCacheEnabled)

                Picker("audio_cache_limit", selection: $settings.audioCacheLimitBytes) {
                    ForEach(Self.audioCacheLimitOptions, id: \.self) { bytes in
                        Text(formatBytes(bytes)).tag(bytes)
                    }
                }

                storageRow(
                    icon: "waveform",
                    title: "audio_cache",
                    size: audioCacheSize,
                    isClearing: isClearingAudio
                ) {
                    isClearingAudio = true
                    Task {
                        let result = await sourceManager.clearAudioCache()
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

            // Debug 区只在 Debug 构建里显示 —— 生产 Release 不出现这个入口,
            // 普通用户看不到 (避免误触把开发日志泄露)。
            #if DEBUG
            Section {
                Button {
                    logShareItem = LogShareItem(url: FileLogger.shared.logFileURL)
                } label: {
                    Label("storage_export_log", systemImage: "square.and.arrow.up.on.square")
                }
            } header: {
                Text("debug")
            } footer: {
                Text("storage_export_log_footer")
            }
            #endif
        }
        .sheet(item: $logShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .navigationTitle("storage_management")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
            if bd.pinnedBytes > 0 {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint).font(.caption)
                    Text("cache_pinned").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.pinnedBytes))
                        .font(.caption).foregroundStyle(.tint).monospacedDigit()
                }
            }

            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary).font(.caption)
                Text("cache_completed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmt.string(fromByteCount: bd.completedBytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if bd.activeBytes > 0 {
                HStack {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.blue).font(.caption)
                    Text("cache_active").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.activeBytes))
                        .font(.caption).foregroundStyle(.blue).monospacedDigit()
                }
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

    private static let audioCacheLimitOptions: [Int64] = [
        1_073_741_824,
        2_147_483_648,
        5_368_709_120,
        10_737_418_240,
        21_474_836_480,
    ]

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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


// MARK: - Share Sheet

#if os(iOS)
/// SwiftUI 包装的 `UIActivityViewController`，让任意 view 通过 `.sheet`
/// 弹出系统分享面板（AirDrop / 微信 / 邮件 / 文件 / 等）。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
/// macOS 等价物 ── 调用 NSSharingServicePicker。SwiftUI sheet 里用 onAppear
/// 在第一次显示时拉起系统分享面板, 然后立即 dismiss 自身。
struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                let picker = NSSharingServicePicker(items: items)
                if let window = NSApp.keyWindow,
                   let view = window.contentView {
                    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                }
                dismiss()
            }
    }
}
#endif

// MARK: - Family Sharing Settings

/// 家庭共享设置入口。
/// - 未启用: 显示"创建家庭包"按钮 → enableFamilySharing 拿到 CKShare → 弹
///   UICloudSharingController 让用户发邀请
/// - 已启用 (owner / participant 通用): 显示状态 + "查看 / 邀请" + "解散 /
///   退出" (destructive)
struct FamilySharingSettingsView: View {
    @Environment(CloudKitSyncService.self) private var sync
    @State private var familyEnabled = CloudKitSyncService.familySharingEnabled
    @State private var pendingShare: CKShare?
    @State private var pendingContainer: CKContainer?
    @State private var showSharingController = false
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        Form {
            // 状态 + 主动作 ── 启用状态和"邀请家人"放一起逻辑紧凑
            Section {
                if familyEnabled {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("family_sharing_active")
                            .font(.subheadline)
                    }
                    Button {
                        Task { await openExistingShare() }
                    } label: {
                        Label("family_sharing_manage", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(isBusy)
                } else {
                    Button {
                        Task { await enable() }
                    } label: {
                        Label("family_sharing_create", systemImage: "person.2.badge.plus")
                    }
                    .disabled(isBusy)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                if !familyEnabled {
                    Text("family_sharing_footer").font(.footnote)
                }
            }

            // 解散 ── 独立 Section, 物理上跟"邀请家人"分开避免 SwiftUI Form
            // 多 Button 同 Section 时点击 highlight 串味。
            if familyEnabled {
                Section {
                    Button(role: .destructive) {
                        Task { await disable() }
                    } label: {
                        Label("family_sharing_leave", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .disabled(isBusy)
                } footer: {
                    Text("family_sharing_footer").font(.footnote)
                }
            }

            Section {
                row("family_sharing_shared_playlists", systemImage: "checkmark")
                row("family_sharing_shared_smart", systemImage: "checkmark")
                row("family_sharing_shared_sources", systemImage: "checkmark")
                row("family_sharing_shared_apple_mirror", systemImage: "checkmark")
            } header: {
                Text("family_sharing_shared_header")
            }

            Section {
                row("family_sharing_private_liked", value: "—")
                row("family_sharing_private_history", value: "—")
                row("family_sharing_private_settings", value: "—")
            } header: {
                Text("family_sharing_private_header")
            } footer: {
                Text("family_sharing_scope_footer")
                    .font(.footnote)
            }
        }
        .navigationTitle("family_sharing_title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSharingController) {
            if let share = pendingShare, let container = pendingContainer {
                CloudSharingControllerView(share: share, container: container) {
                    showSharingController = false
                    familyEnabled = CloudKitSyncService.familySharingEnabled
                }
            }
        }
    }

    private func row(_ key: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(key)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func row(_ key: LocalizedStringKey, systemImage: String) -> some View {
        HStack {
            Text(key)
                .font(.subheadline)
            Spacer()
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.green)
        }
    }

    @MainActor
    private func enable() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let share = try await sync.enableFamilySharing()
            pendingShare = share
            pendingContainer = CKContainer(identifier: CloudKitSyncService.containerID)
            familyEnabled = true
            showSharingController = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func openExistingShare() async {
        isBusy = true
        defer { isBusy = false }
        // 重新启用一次拿到当前 share, 让用户能看到成员 / 重新发邀请。
        // enableFamilySharing 是幂等的 ── zone / holder 已在时只追加邀请逻辑。
        do {
            let share = try await sync.enableFamilySharing()
            pendingShare = share
            pendingContainer = CKContainer(identifier: CloudKitSyncService.containerID)
            showSharingController = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func disable() async {
        isBusy = true
        defer { isBusy = false }
        await sync.disableFamilySharing()
        familyEnabled = false
    }
}

#if os(iOS)
/// SwiftUI 包 UICloudSharingController ── Apple 提供的 share 邀请 UI, 自带
/// iMessage / 邮件 / 复制链接发送、成员列表、权限调整、移除成员等全套功能。
/// macOS 没有 UICloudSharingController, 用 NSSharingService 走另一套实现。
struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let vc = UICloudSharingController(share: share, container: container)
        vc.delegate = context.coordinator
        vc.availablePermissions = [.allowReadWrite, .allowPrivate]
        return vc
    }

    func updateUIViewController(_ vc: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDismiss()
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            plog("⚠️ UICloudSharingController save failed: \(error.localizedDescription)")
        }
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Primuse Family"
        }
    }
}
#else
/// macOS 端 ── 用 NSSharingServicePicker 弹邀请 panel (iCloud sharing 走系统
/// 内置的 sharing service)。stub 占位先编过, 完整 UI 在分析阶段做。
struct CloudSharingControllerView: View {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1).onAppear { onDismiss() }
    }
}
#endif
