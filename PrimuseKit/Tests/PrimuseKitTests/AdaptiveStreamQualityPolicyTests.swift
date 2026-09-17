import Foundation
import Testing
@testable import PrimuseKit

@Suite("Adaptive Stream Quality Policy")
struct AdaptiveStreamQualityPolicyTests {

    // 一首典型的无损曲目：FLAC、1000 kbps、40MB、4 分钟。
    private func losslessPlan(
        wifi: StreamQualityPreference,
        cellular: StreamQualityPreference,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) -> SourceTranscodePlan {
        AdaptiveStreamQualityPolicy.plan(
            wifiPreference: wifi,
            cellularPreference: cellular,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            formatIsLossless: true,
            formatRequiresCompleteLocalFile: false,
            sourceBitRateKbps: 1000,
            fileSize: 40 * 1024 * 1024,
            duration: 240
        )
    }

    // MARK: - 默认不变

    @Test("两项都是原始时永远不转码")
    func defaultPreferencesNeverTranscode() {
        for expensive in [false, true] {
            for constrained in [false, true] {
                let plan = losslessPlan(
                    wifi: .original,
                    cellular: .original,
                    isExpensive: expensive,
                    isConstrained: constrained
                )
                #expect(plan == .original)
            }
        }
    }

    @Test("StreamQualityPreference 的默认 case 是 original 且没有目标码率")
    func originalHasNoTarget() {
        #expect(StreamQualityPreference.original.targetBitRateKbps == nil)
        #expect(StreamQualityPreference.kbps320.targetBitRateKbps == 320)
        #expect(StreamQualityPreference.kbps192.targetBitRateKbps == 192)
        #expect(StreamQualityPreference.kbps128.targetBitRateKbps == 128)
        #expect(StreamQualityPreference.allCases.count == 4)
    }

    @Test("原始枚举值可以从旧 JSON 之外的字符串安全还原")
    func rawValuesAreStable() {
        #expect(StreamQualityPreference(rawValue: "original") == .original)
        #expect(StreamQualityPreference(rawValue: "kbps128") == .kbps128)
        #expect(StreamQualityPreference(rawValue: "320") == nil)
    }

    // MARK: - 按网络选项

    @Test("Wi-Fi 上不读移动网络那一项")
    func wifiIgnoresCellularPreference() {
        let plan = losslessPlan(wifi: .original, cellular: .kbps128)
        #expect(plan == .original)
    }

    @Test("蜂窝网络用移动网络那一项")
    func expensiveUsesCellularPreference() {
        let plan = losslessPlan(wifi: .original, cellular: .kbps128, isExpensive: true)
        #expect(plan == .transcode(bitRateKbps: 128))
    }

    @Test("低数据模式也按移动网络处理")
    func constrainedUsesCellularPreference() {
        let plan = losslessPlan(wifi: .original, cellular: .kbps192, isConstrained: true)
        #expect(plan == .transcode(bitRateKbps: 192))
    }

    @Test("Wi-Fi 那一项非原始时在 Wi-Fi 上生效")
    func wifiPreferenceApplies() {
        let plan = losslessPlan(wifi: .kbps320, cellular: .original)
        #expect(plan == .transcode(bitRateKbps: 320))
    }

    @Test("activePreference 的选择与 plan 一致")
    func activePreferenceSelection() {
        #expect(AdaptiveStreamQualityPolicy.activePreference(
            wifiPreference: .kbps320, cellularPreference: .kbps128,
            isExpensive: false, isConstrained: false) == .kbps320)
        #expect(AdaptiveStreamQualityPolicy.activePreference(
            wifiPreference: .kbps320, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false) == .kbps128)
        #expect(AdaptiveStreamQualityPolicy.activePreference(
            wifiPreference: .kbps320, cellularPreference: .kbps128,
            isExpensive: false, isConstrained: true) == .kbps128)
    }

    // MARK: - 有损源的收益判断

    @Test("有损且码率不高于目标时不转码")
    func lossyBelowTargetStaysOriginal() {
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps192,
            isExpensive: true, isConstrained: false,
            formatIsLossless: false, formatRequiresCompleteLocalFile: false,
            sourceBitRateKbps: 192, fileSize: 6 * 1024 * 1024, duration: 240
        )
        #expect(plan == .original)
    }

    @Test("有损但码率高于目标时转码")
    func lossyAboveTargetTranscodes() {
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false,
            formatIsLossless: false, formatRequiresCompleteLocalFile: false,
            sourceBitRateKbps: 320, fileSize: 9 * 1024 * 1024, duration: 240
        )
        #expect(plan == .transcode(bitRateKbps: 128))
    }

    @Test("有损但码率信息完全缺失时保持原始")
    func lossyWithoutBitRateInfoStaysOriginal() {
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false,
            formatIsLossless: false, formatRequiresCompleteLocalFile: false,
            sourceBitRateKbps: nil, fileSize: 0, duration: 240
        )
        #expect(plan == .original)
    }

    @Test("码率缺失但能用 fileSize/duration 估算时照常判断")
    func lossyEstimatesBitRateFromSize() {
        // 9,600,000 字节 / 240 秒 = 320 kbps
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false,
            formatIsLossless: false, formatRequiresCompleteLocalFile: false,
            sourceBitRateKbps: nil, fileSize: 9_600_000, duration: 240
        )
        #expect(plan == .transcode(bitRateKbps: 128))
    }

    @Test("估算码率的算式")
    func effectiveBitRateEstimation() {
        #expect(AdaptiveStreamQualityPolicy.effectiveSourceBitRateKbps(
            sourceBitRateKbps: 256, fileSize: 0, duration: 0) == 256)
        #expect(AdaptiveStreamQualityPolicy.effectiveSourceBitRateKbps(
            sourceBitRateKbps: nil, fileSize: 9_600_000, duration: 240) == 320)
        #expect(AdaptiveStreamQualityPolicy.effectiveSourceBitRateKbps(
            sourceBitRateKbps: 0, fileSize: 0, duration: 240) == nil)
        #expect(AdaptiveStreamQualityPolicy.effectiveSourceBitRateKbps(
            sourceBitRateKbps: nil, fileSize: 1024, duration: 0) == nil)
    }

    @Test("无损源不看码率，一律转码")
    func losslessAlwaysTranscodes() {
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false,
            formatIsLossless: true, formatRequiresCompleteLocalFile: false,
            sourceBitRateKbps: nil, fileSize: 0, duration: 240
        )
        #expect(plan == .transcode(bitRateKbps: 128))
    }

    // MARK: - 排除条件

    @Test("需要完整本地文件的格式保持原始")
    func completeFileFormatsStayOriginal() {
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false,
            formatIsLossless: true, formatRequiresCompleteLocalFile: true,
            sourceBitRateKbps: 1000, fileSize: 40 * 1024 * 1024, duration: 240
        )
        #expect(plan == .original)
    }

    @Test("CUE 分轨保持原始")
    func cueTracksStayOriginal() {
        let plan = AdaptiveStreamQualityPolicy.plan(
            wifiPreference: .original, cellularPreference: .kbps128,
            isExpensive: true, isConstrained: false,
            formatIsLossless: true, formatRequiresCompleteLocalFile: false,
            isCueTrack: true,
            sourceBitRateKbps: 1000, fileSize: 400 * 1024 * 1024, duration: 240
        )
        #expect(plan == .original)
    }

    @Test("时长未知时保持原始")
    func missingDurationStaysOriginal() {
        for duration in [0.0, -1.0, Double.nan, Double.infinity] {
            let plan = AdaptiveStreamQualityPolicy.plan(
                wifiPreference: .original, cellularPreference: .kbps128,
                isExpensive: true, isConstrained: false,
                formatIsLossless: true, formatRequiresCompleteLocalFile: false,
                sourceBitRateKbps: 1000, fileSize: 40 * 1024 * 1024, duration: duration
            )
            #expect(plan == .original)
        }
    }

    // MARK: - URL 标记

    @Test("识别 adaptive 标记")
    func detectsAdaptiveMarker() {
        let adaptive = URL(string: "https://h/rest/stream.view?id=1&format=mp3&maxBitRate=128&primuse_transcoded=1&primuse_adaptive=1")!
        let wmaOnly = URL(string: "https://h/rest/stream.view?id=1&format=mp3&maxBitRate=320&primuse_transcoded=1")!
        let raw = URL(string: "https://h/rest/stream.view?id=1&format=raw")!
        #expect(AdaptiveStreamQualityPolicy.isAdaptiveTranscodedStreamURL(adaptive))
        #expect(!AdaptiveStreamQualityPolicy.isAdaptiveTranscodedStreamURL(wmaOnly))
        #expect(!AdaptiveStreamQualityPolicy.isAdaptiveTranscodedStreamURL(raw))
        #expect(!AdaptiveStreamQualityPolicy.isAdaptiveTranscodedStreamURL(URL(fileURLWithPath: "/tmp/a.flac")))
    }

    @Test("从已解析的 URL 反推计划")
    func planFromResolvedURL() {
        let adaptive = URL(string: "https://h/rest/stream.view?id=1&format=mp3&maxBitRate=192&primuse_transcoded=1&primuse_adaptive=1")!
        #expect(AdaptiveStreamQualityPolicy.plan(fromResolvedURL: adaptive) == .transcode(bitRateKbps: 192))

        let wmaOnly = URL(string: "https://h/rest/stream.view?id=1&format=mp3&maxBitRate=320&primuse_transcoded=1")!
        #expect(AdaptiveStreamQualityPolicy.plan(fromResolvedURL: wmaOnly) == .original)

        let noBitRate = URL(string: "https://h/rest/stream.view?id=1&format=mp3&primuse_adaptive=1")!
        #expect(AdaptiveStreamQualityPolicy.plan(fromResolvedURL: noBitRate) == .original)

        let bogusBitRate = URL(string: "https://h/rest/stream.view?id=1&maxBitRate=abc&primuse_adaptive=1")!
        #expect(AdaptiveStreamQualityPolicy.plan(fromResolvedURL: bogusBitRate) == .original)

        #expect(AdaptiveStreamQualityPolicy.plan(
            fromResolvedURL: URL(fileURLWithPath: "/tmp/a.mp3")) == .original)
    }

    @Test("带反代前缀与端口的地址同样能识别")
    func detectsMarkerBehindProxyPrefix() {
        let url = URL(string: "https://h:8443/music/nav/rest/stream.view?u=u&t=t&s=s&v=1.16.1&c=Primuse&f=json&id=1&format=mp3&maxBitRate=128&primuse_transcoded=1&primuse_adaptive=1")!
        #expect(AdaptiveStreamQualityPolicy.isAdaptiveTranscodedStreamURL(url))
        #expect(AdaptiveStreamQualityPolicy.plan(fromResolvedURL: url) == .transcode(bitRateKbps: 128))
    }

    // MARK: - 落盘

    @Test("转码文件名可用且不同 id 不相撞")
    func transcodeFileNames() {
        let a = AdaptiveStreamQualityPolicy.transcodeFileName(songID: "abc123", bitRateKbps: 128)
        let b = AdaptiveStreamQualityPolicy.transcodeFileName(songID: "abc123", bitRateKbps: 192)
        let c = AdaptiveStreamQualityPolicy.transcodeFileName(songID: "abc/123", bitRateKbps: 128)
        #expect(a.hasSuffix(".mp3"))
        #expect(a != b)
        #expect(a != c)
        #expect(!c.contains("/"))
        // 相同输入必须稳定 —— 换歌回来要能命中同一个文件。
        #expect(a == AdaptiveStreamQualityPolicy.transcodeFileName(songID: "abc123", bitRateKbps: 128))
    }

    @Test("文件名同时是预取去重键")
    func fileNameIsTheDedupKey() {
        // 同一首歌同一码率 —— 播放撞上在途预取时必须 join 到同一个键上，
        // 否则会出现两个写者写同一个路径。
        let a = AdaptiveStreamQualityPolicy.transcodeFileName(songID: "song-a", bitRateKbps: 128)
        let again = AdaptiveStreamQualityPolicy.transcodeFileName(songID: "song-a", bitRateKbps: 128)
        #expect(a == again)
        // 改了设置就是另一份产物，不能复用上一份
        #expect(a != AdaptiveStreamQualityPolicy.transcodeFileName(songID: "song-a", bitRateKbps: 320))
        // 不同歌各自一份
        #expect(a != AdaptiveStreamQualityPolicy.transcodeFileName(songID: "song-b", bitRateKbps: 128))
    }

    @Test("清洗后为空的 id 仍产出合法文件名")
    func transcodeFileNameFallback() {
        let name = AdaptiveStreamQualityPolicy.transcodeFileName(songID: "///", bitRateKbps: 128)
        #expect(name.hasPrefix("song-"))
        #expect(name.hasSuffix("-128.mp3"))
    }

    @Test("指纹跨调用稳定")
    func fingerprintIsStable() {
        #expect(AdaptiveStreamQualityPolicy.stableFingerprint("abc")
            == AdaptiveStreamQualityPolicy.stableFingerprint("abc"))
        #expect(AdaptiveStreamQualityPolicy.stableFingerprint("abc")
            != AdaptiveStreamQualityPolicy.stableFingerprint("abd"))
    }

    @Test("转码下载配额按码率与时长估算并留余量")
    func transferBudget() {
        // 128 kbps × 240s = 3,840,000 字节；1.5 倍 + 1MB 余量。
        let budget = AdaptiveStreamQualityPolicy.maximumTranscodedTransferBytes(
            bitRateKbps: 128, duration: 240)
        #expect(budget > 3_840_000)
        #expect(budget < 8_000_000)

        // 参数无效时给一个下限而不是 0，否则下载会被立刻截断。
        #expect(AdaptiveStreamQualityPolicy.maximumTranscodedTransferBytes(
            bitRateKbps: 0, duration: 240) == AdaptiveStreamQualityPolicy.minimumTranscodedTransferBytes)
        #expect(AdaptiveStreamQualityPolicy.maximumTranscodedTransferBytes(
            bitRateKbps: 128, duration: 0) == AdaptiveStreamQualityPolicy.minimumTranscodedTransferBytes)

        // 极长的曲目被硬上限夹住。
        #expect(AdaptiveStreamQualityPolicy.maximumTranscodedTransferBytes(
            bitRateKbps: 320, duration: 200_000)
            == AdaptiveStreamQualityPolicy.maximumTranscodedTransferCeilingBytes)
    }

    @Test("容量以内不删任何转码文件")
    func evictionNoopUnderLimit() {
        let files = [
            AdaptiveTranscodeFileRecord(name: "a.mp3", byteCount: 100, lastAccessedAt: Date(timeIntervalSince1970: 1)),
            AdaptiveTranscodeFileRecord(name: "b.mp3", byteCount: 100, lastAccessedAt: Date(timeIntervalSince1970: 2)),
        ]
        #expect(AdaptiveStreamQualityPolicy.filesToEvict(files, limitBytes: 1000).isEmpty)
    }

    @Test("超额时按最近访问从旧到新删，受保护的保留")
    func evictionOrder() {
        let files = [
            AdaptiveTranscodeFileRecord(name: "old.mp3", byteCount: 400, lastAccessedAt: Date(timeIntervalSince1970: 1)),
            AdaptiveTranscodeFileRecord(name: "mid.mp3", byteCount: 400, lastAccessedAt: Date(timeIntervalSince1970: 2)),
            AdaptiveTranscodeFileRecord(name: "new.mp3", byteCount: 400, lastAccessedAt: Date(timeIntervalSince1970: 3)),
        ]
        let victims = AdaptiveStreamQualityPolicy.filesToEvict(files, limitBytes: 800)
        #expect(victims == ["old.mp3"])

        let protectedVictims = AdaptiveStreamQualityPolicy.filesToEvict(
            files, limitBytes: 800, keeping: ["old.mp3"])
        #expect(protectedVictims == ["mid.mp3"])
    }

    // MARK: - 坏文件防护

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test("正常 mp3 响应被接受")
    func acceptsRealAudio() {
        // ID3 头
        let verdict = AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "audio/mpeg",
            byteCount: 3_840_000,
            leadingBytes: bytes("ID3\u{03}")
        )
        #expect(verdict == .accepted)
        // 裸 MPEG 帧同步
        #expect(AdaptiveStreamQualityPolicy.acceptsTranscodedPayload(
            contentType: "audio/mpeg", byteCount: 3_840_000, leadingBytes: [0xFF, 0xFB, 0x90, 0x44]))
        // 没有 Content-Type 也不该一票否决
        #expect(AdaptiveStreamQualityPolicy.acceptsTranscodedPayload(
            contentType: nil, byteCount: 3_840_000, leadingBytes: [0xFF, 0xFB]))
    }

    @Test("JSON / XML / HTML 错误体被拒")
    func rejectsErrorBodies() {
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "application/json", byteCount: 3_840_000, leadingBytes: bytes("{\"sub"))
            == .rejectedContentType("application/json"))
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "text/xml; charset=utf-8", byteCount: 3_840_000, leadingBytes: bytes("<?xml"))
            == .rejectedContentType("text/xml; charset=utf-8"))
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "text/plain", byteCount: 3_840_000, leadingBytes: bytes("oops"))
            == .rejectedContentType("text/plain"))
    }

    @Test("Content-Type 撒谎时靠首字节拦住")
    func rejectsTextualBodyDespiteAudioContentType() {
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "audio/mpeg", byteCount: 3_840_000, leadingBytes: bytes("{\"subsonic-response\":"))
            == .rejectedTextualBody)
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "audio/mpeg", byteCount: 3_840_000, leadingBytes: bytes("  \n<!DOCTYPE html>"))
            == .rejectedTextualBody)
        // BOM 开头的 JSON 同样要拦住
        var bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        bom.append(contentsOf: bytes("{\"error\""))
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "audio/mpeg", byteCount: 3_840_000, leadingBytes: bom)
            == .rejectedTextualBody)
    }

    @Test("过小的响应体被拒")
    func rejectsTinyBodies() {
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "audio/mpeg", byteCount: 512, leadingBytes: [0xFF, 0xFB])
            == .rejectedTooSmall(512))
        #expect(AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: "audio/mpeg", byteCount: 0, leadingBytes: [])
            == .rejectedTooSmall(0))
        // 正好到下限要通过
        #expect(AdaptiveStreamQualityPolicy.acceptsTranscodedPayload(
            contentType: "audio/mpeg",
            byteCount: AdaptiveStreamQualityPolicy.minimumTranscodedPayloadBytes,
            leadingBytes: [0xFF, 0xFB]))
    }

    @Test("全部受保护时一个都不删")
    func evictionRespectsProtection() {
        let files = [
            AdaptiveTranscodeFileRecord(name: "a.mp3", byteCount: 900, lastAccessedAt: Date(timeIntervalSince1970: 1)),
        ]
        #expect(AdaptiveStreamQualityPolicy.filesToEvict(
            files, limitBytes: 100, keeping: ["a.mp3"]).isEmpty)
    }
}
