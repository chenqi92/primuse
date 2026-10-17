import Foundation
import Observation
import PrimuseKit

/// Apple TV 上的歌词罗马音：歌词装上屏时按设置生成（与 iPhone、Mac 同一套服务与缓存），
/// 结果按行 id 存在这里，歌词列表与全屏效果显示时按「罗马音显示」套上去。不写进歌词数据。
@MainActor
@Observable
final class TVLyricsRomanizationController {
    static let shared = TVLyricsRomanizationController()

    /// 当前歌词各行生成的罗马音（行 id → 罗马音）。
    private(set) var generated: [String: String] = [:]
    /// `generated` 属于哪一首。
    private(set) var songID: String?

    /// App 启动时设置；选了「智能功能」生成时要用它。
    @ObservationIgnored weak var intelligence: MusicIntelligenceService?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastLoaded: (songID: String, lines: [LyricLine])?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .lyricsRomanizationSettingsChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TVLyricsRomanizationController.shared.start() }
        })
    }

    /// 歌词装上屏时调用（与翻译控制器同一处）。
    func lyricsDidLoad(_ lines: [LyricLine], forSongID songID: String) {
        lastLoaded = (songID, lines)
        start()
    }

    /// 这一行按「罗马音显示」该怎么画：文件自带的罗马音优先，其次是生成的；
    /// 「只显示罗马音」时正文换成罗马音、去掉逐字时间（罗马音没有逐字时间，按整行高亮）。
    func displayLine(_ line: TVLyricLine, songID currentSongID: String?) -> TVLyricLine {
        let mode = LyricsRomanizationSettingsStore.shared.displayMode
        let generated = currentSongID != nil && currentSongID == songID ? self.generated : [:]
        return line.romanizedForDisplay(generated: generated, mode: mode)
    }

    private func start() {
        task?.cancel()
        guard let loaded = lastLoaded, !loaded.lines.isEmpty else {
            generated = [:]
            songID = lastLoaded?.songID
            return
        }
        if songID != loaded.songID {
            generated = [:]
            songID = loaded.songID
        }
        let settings = LyricsRomanizationSettingsStore.shared
        let intelligence = intelligence
        let generates = settings.isAutoGenerationEnabled
        let method = generates
            ? LyricRomanizationMethodPolicy.effectiveMethod(
                settings.method,
                region: intelligence?.regionAvailability.context.region ?? .unknown,
                exposesIntelligentServices: intelligence?.shouldExposeRemoteConfiguration ?? false
            )
            : .local
        let request = LyricsRomanizationService.Request(
            // 和屏幕上那份同一套行 id（「显示歌词自带的译文」关掉时去掉了译文，读音行留着）。
            lines: TVLyricsTranslationController.presentedLines(loaded.lines),
            generates: generates,
            enabledLanguages: generates ? settings.enabledLanguages : [],
            method: method,
            songContext: .init()
        )
        let songID = loaded.songID
        task = Task { @MainActor [weak self] in
            let result = await LyricsRomanizationService.shared.overlay(
                for: request,
                intelligence: intelligence
            ) { partial in
                guard let self, !Task.isCancelled, self.songID == songID else { return }
                self.generated = partial.generatedTextByLineID
            }
            guard let self, let result, !Task.isCancelled, self.songID == songID else { return }
            self.generated = result.generatedTextByLineID
        }
    }
}

extension TVLyricLine {
    /// 按罗马音设置换过的这一行（和声行一并处理）。没有要改的时候原样返回。
    func romanizedForDisplay(
        generated: [String: String],
        mode: LyricRomanizationDisplayMode
    ) -> TVLyricLine {
        let decision = LyricRomanizationDisplayPolicy.decision(
            authored: romanization,
            generated: generated[id],
            mode: mode
        )
        let companion = decision.companion ?? ""
        let replacement = decision.replacementText
        let displayedBackground = background.map { $0.romanizedForDisplay(generated: generated, mode: mode) }
        guard replacement != nil || companion != romanization || displayedBackground != background else {
            return self
        }
        return TVLyricLine(
            id: id,
            time: time,
            text: replacement ?? text,
            isSynchronized: isSynchronized,
            syllables: replacement == nil ? syllables : [],
            translation: translation,
            romanization: companion,
            writingDirection: replacement == nil ? writingDirection : .leftToRight,
            voice: voice,
            background: displayedBackground
        )
    }
}
