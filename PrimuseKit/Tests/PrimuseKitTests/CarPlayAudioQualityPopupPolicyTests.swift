import Testing
@testable import PrimuseKit

@Suite("CarPlay audio quality popup policy")
struct CarPlayAudioQualityPopupPolicyTests {
    private let labels = CarPlayAudioQualityPopupPolicy.Labels(
        original: "原始音质",
        kbps320: "320 kbps",
        kbps256: "256 kbps",
        kbps192: "192 kbps",
        kbps128: "128 kbps",
        ok: "好",
        originalFilePrefix: "原始文件",
        outputPrefix: "音频输出",
        fallbackTitle: "音质"
    )

    private func losslessSong() -> Song {
        Song(
            id: "s1",
            title: "Track",
            duration: 210,
            fileFormat: .flac,
            filePath: "/songs/1.flac",
            sourceID: "navidrome-1",
            bitRate: 2_304,
            sampleRate: 96_000,
            bitDepth: 24
        )
    }

    @Test("Transcodable source offers horizontal bitrate buttons with active selection marked")
    func transcodableSourceHorizontalButtons() {
        let quality = CarPlayAudioQualityText(song: losslessSong(), transcodePlan: .original)
        let presentation = CarPlayAudioQualityPopupPolicy.presentation(
            quality: quality,
            outputSampleRateText: "96 kHz",
            supportsBitrateSwitching: true,
            activePreference: .original,
            maximumActionCount: 3,
            labels: labels
        )

        #expect(presentation.titleVariants == [
            "FLAC · 24bit/96kHz · 2304kbps\n音频输出: 96 kHz",
            "FLAC · 24bit/96kHz · 2304kbps",
            "FLAC · 24/96 · 2304k",
        ])
        #expect(presentation.actions == [
            .init(title: "✓ 原始音质", kind: .dismiss, isSelected: true, isCancelStyle: true),
            .init(title: "320 kbps", kind: .selectQuality(.kbps320), isSelected: false, isCancelStyle: false),
            .init(title: "128 kbps", kind: .selectQuality(.kbps128), isSelected: false, isCancelStyle: false),
        ])
    }

    @Test("Transcoded stream includes original file specs and preserves non-default active preset")
    func transcodedStreamKeepsActiveMiddlePreset() {
        let quality = CarPlayAudioQualityText(
            song: losslessSong(),
            transcodePlan: .transcode(bitRateKbps: 192, format: .mp3)
        )
        let presentation = CarPlayAudioQualityPopupPolicy.presentation(
            quality: quality,
            outputSampleRateText: "48 kHz",
            supportsBitrateSwitching: true,
            activePreference: .kbps192,
            maximumActionCount: 3,
            labels: labels
        )

        #expect(presentation.titleVariants.first == "MP3 · 192kbps · 音频输出 48 kHz\n原始文件: FLAC · 24bit/96kHz · 2304kbps")
        #expect(presentation.titleVariants.contains("MP3 · 192kbps\n原始文件: FLAC · 24bit/96kHz · 2304kbps"))
        #expect(presentation.titleVariants.last == "MP3 · 192k")
        #expect(presentation.actions.map(\.title) == ["原始音质", "✓ 192 kbps", "128 kbps"])
        #expect(presentation.actions.map(\.kind) == [
            .selectQuality(.original),
            .dismiss,
            .selectQuality(.kbps128),
        ])
        #expect(presentation.actions.map(\.isCancelStyle) == [false, true, false])
    }

    @Test("Non-transcodable source shows specs and single dismiss action")
    func unsupportedSourceShowsDismissOnly() {
        let quality = CarPlayAudioQualityText(song: losslessSong(), transcodePlan: .original)
        let presentation = CarPlayAudioQualityPopupPolicy.presentation(
            quality: quality,
            outputSampleRateText: nil,
            supportsBitrateSwitching: false,
            activePreference: .kbps320,
            maximumActionCount: 3,
            labels: labels
        )

        #expect(presentation.titleVariants == [
            "FLAC · 24bit/96kHz · 2304kbps",
            "FLAC · 24/96 · 2304k",
        ])
        #expect(presentation.actions == [
            .init(title: "好", kind: .dismiss, isSelected: false, isCancelStyle: true),
        ])
    }

    @Test("Action limits below two fall back to dismiss and larger limits expand presets")
    func respectsActionLimits() {
        let quality = CarPlayAudioQualityText(song: losslessSong(), transcodePlan: .original)
        let oneButton = CarPlayAudioQualityPopupPolicy.presentation(
            quality: quality,
            outputSampleRateText: nil,
            supportsBitrateSwitching: true,
            activePreference: .original,
            maximumActionCount: 1,
            labels: labels
        )
        #expect(oneButton.actions == [.init(title: "好", kind: .dismiss, isSelected: false, isCancelStyle: true)])

        let twoButtons = CarPlayAudioQualityPopupPolicy.horizontalPresets(activePreference: .kbps128, limit: 2)
        #expect(twoButtons == [.original, .kbps128])

        let fourButtons = CarPlayAudioQualityPopupPolicy.horizontalPresets(activePreference: .kbps192, limit: 4)
        #expect(fourButtons == [.original, .kbps320, .kbps192, .kbps128])

        let allButtons = CarPlayAudioQualityPopupPolicy.horizontalPresets(activePreference: .original, limit: 5)
        #expect(allButtons == StreamQualityPreference.allCases)
    }
}
