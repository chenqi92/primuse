import PrimuseKit
import SwiftUI

extension View {
    /// 给正在显示的歌词生成罗马音。和翻译任务挂在同一处：歌词真的展示在某处时才算，
    /// 换歌、歌词变了、改了设置就取消重来。结果只用于显示，不写进歌词文件、缓存或编辑器。
    func lyricsRomanizationTask(
        songID: String?,
        songContext: LyricTranslationSongContext,
        lyricsRevision: UInt,
        lyrics: [LyricLine],
        overlay: Binding<LyricRomanizationOverlay>
    ) -> some View {
        modifier(LyricsRomanizationTaskModifier(
            songID: songID,
            songContext: songContext,
            lyricsRevision: lyricsRevision,
            lyrics: lyrics,
            overlay: overlay
        ))
    }
}

struct LyricsRomanizationTaskModifier: ViewModifier {
    /// 迷你播放器窗口这类环境里可能没有智能功能服务；读不到就只用本机或 Google Cloud。
    @Environment(MusicIntelligenceService.self) private var intelligence: MusicIntelligenceService?
    let songID: String?
    let songContext: LyricTranslationSongContext
    let lyricsRevision: UInt
    let lyrics: [LyricLine]
    @Binding var overlay: LyricRomanizationOverlay
    /// 当前结果属于哪一首、哪一份歌词。
    @State private var overlayLyricsKey: String?

    private var settings: LyricsRomanizationSettingsStore { .shared }
    private var googleAccount: GoogleCloudRomanizationAccount { .shared }

    private struct Identity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let generates: Bool
        let enabledLanguages: [LyricRomanizationLanguage]
        let method: LyricRomanizationMethod
        /// 选了智能功能时它此刻发不发得出去；同意了、配好了服务就重来。
        let intelligentReadiness: LyricsAITranslationReadiness?
        let intelligentEngineID: String?
        /// 导入或移除 Google 服务账号密钥。
        let googleRevision: UInt?
    }

    private var effectiveMethod: LyricRomanizationMethod {
        LyricRomanizationMethodPolicy.effectiveMethod(
            settings.method,
            region: intelligence?.regionAvailability.context.region ?? .unknown,
            exposesIntelligentServices: intelligence?.shouldExposeRemoteConfiguration ?? false
        )
    }

    private var identity: Identity {
        let generates = settings.isAutoGenerationEnabled
        let method = generates ? effectiveMethod : .local
        return Identity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            generates: generates,
            enabledLanguages: generates
                ? settings.enabledLanguages.sorted { $0.rawValue < $1.rawValue }
                : [],
            method: method,
            intelligentReadiness: method == .intelligent ? intelligence?.lyricsAIRomanizationReadiness : nil,
            intelligentEngineID: method == .intelligent ? intelligence?.lyricsRomanizationEngineID : nil,
            googleRevision: method == .googleCloud ? googleAccount.revision : nil
        )
    }

    func body(content: Content) -> some View {
        content.task(id: identity) {
            await generate(for: identity)
        }
    }

    private func generate(for identity: Identity) async {
        guard !Task.isCancelled, self.identity == identity else { return }
        // 换了一首歌或者一份歌词：旧结果的行 id 对不上了，先清掉。只是改了设置时留着旧结果，
        // 新结果算出来再换，免得「只显示罗马音」时整首闪回原文。
        let lyricsKey = "\(identity.songID ?? "")|\(identity.lyricsRevision)"
        if overlayLyricsKey != lyricsKey {
            overlayLyricsKey = lyricsKey
            overlay = .empty
        }
        guard !lyrics.isEmpty else {
            overlay = .empty
            return
        }
        let request = LyricsRomanizationService.Request(
            lines: lyrics,
            generates: identity.generates,
            enabledLanguages: Set(identity.enabledLanguages),
            method: identity.method,
            songContext: songContext
        )
        let result = await LyricsRomanizationService.shared.overlay(
            for: request,
            intelligence: intelligence
        ) { partial in
            guard !Task.isCancelled, self.identity == identity else { return }
            // 第一组结果出来之前不动旧结果；之后按最新的一组接着补。
            overlay = partial
        }
        guard let result, !Task.isCancelled, self.identity == identity else { return }
        overlay = result
    }
}
