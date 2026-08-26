import SwiftUI
import PrimuseKit

/// 歌词翻译设置 — 用 Apple Translation Framework 离线翻译。
/// 已安装语言包自动工作；缺少语言包时播放器先显示显式翻译操作，只有用户
/// 点击后才允许系统展示下载或源语言确认界面。
struct LyricsTranslationSettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var settings = LyricsTranslationSettingsStore.shared
    @State private var languageCatalog = LyricsTranslationLanguageCatalog.shared
    @State private var cacheCount: Int = 0
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("lyrics_translation_enabled", isOn: $settings.isEnabled)
            } footer: {
                Text("lyrics_translation_overall_footer")
            }

            if settings.isEnabled {
                Section {
                    Picker("lyrics_translation_mode", selection: displayedMode) {
                        Text("lyrics_translation_mode_system")
                            .tag(LyricsTranslationMode.system)
                        if intelligence.shouldExposeRemoteConfiguration {
                            Text("lyrics_translation_mode_intelligent")
                                .tag(LyricsTranslationMode.intelligentWithSystemFallback)
                        }
                    }
                } footer: {
                    Text(displayedMode.wrappedValue == .system
                         ? "lyrics_translation_mode_system_footer"
                         : "lyrics_translation_mode_intelligent_footer")
                }

                Section("lyrics_translation_target_language") {
                    Picker("lyrics_translation_target", selection: $settings.targetLanguageCode) {
                        ForEach(
                            languageCatalog.options(including: settings.targetLanguageCode),
                            id: \.self
                        ) { code in
                            Text(languageCatalog.displayName(for: code)).tag(code)
                        }
                    }
                }

                Section {
                    HStack {
                        Label("lyrics_translation_cached", systemImage: "internaldrive")
                        Spacer()
                        Text("\(cacheCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if cacheCount > 0 {
                        Button("lyrics_translation_clear_cache", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                } header: {
                    Text("lyrics_translation_cache_section")
                } footer: {
                    Text("lyrics_translation_cache_footer")
                }
            }
        }
        .navigationTitle("lyrics_translation_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            cacheCount = LyricsTranslationCache.shared.count
        }
        .task {
            await languageCatalog.refresh()
        }
        .confirmationDialog(
            "lyrics_translation_clear_confirm",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("clear_all", role: .destructive) {
                LyricsTranslationCache.shared.clearAll()
                cacheCount = 0
            }
            Button("cancel", role: .cancel) {}
        }
        #if os(macOS)
        .macReadablePane(maxWidth: 720)
        #endif
    }

    private var displayedMode: Binding<LyricsTranslationMode> {
        Binding(
            get: {
                intelligence.shouldExposeRemoteConfiguration ? settings.mode : .system
            },
            set: { settings.mode = $0 }
        )
    }
}
