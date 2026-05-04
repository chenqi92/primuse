import SwiftUI
import PrimuseKit

/// 歌词翻译设置 — 用 Apple Translation Framework 离线翻译。
/// 第一次启用 + 首次播放时, 系统会弹出对应语言对的下载提示
/// (~100MB), 用户接受后下载完毕后续秒翻译。
struct LyricsTranslationSettingsView: View {
    @State private var settings = LyricsTranslationSettingsStore.shared
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
                Section("lyrics_translation_target_language") {
                    Picker("lyrics_translation_target", selection: $settings.targetLanguageCode) {
                        ForEach(LyricsTranslationSettingsStore.availableTargetLanguages, id: \.code) { lang in
                            Text(LocalizedStringKey(lang.displayKey)).tag(lang.code)
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
    }
}
