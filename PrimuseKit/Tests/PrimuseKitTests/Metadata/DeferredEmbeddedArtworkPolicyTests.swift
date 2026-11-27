import Testing
@testable import PrimuseKit

@Suite("Deferred embedded artwork")
struct DeferredEmbeddedArtworkPolicyTests {
    // MARK: 手动重读什么时候整首读

    private func reason(
        explicit: Bool = true,
        local: Bool = false,
        decoder: Bool = false,
        unknown: Bool = false,
        technical: Bool = true,
        missingBefore: Bool = false,
        missingAfter: Bool = false,
        missedArtwork: Bool = false,
        containerComplete: Bool = false
    ) -> DeferredEmbeddedArtworkPolicy.CompleteFileReadReason? {
        DeferredEmbeddedArtworkPolicy.completeFileReadReason(
            isExplicitReread: explicit,
            readsLocalFileDirectly: local,
            requiresDecoder: decoder,
            signatureUnknown: unknown,
            hasTechnicalProperties: technical,
            durationMissingFromBoundedTags: missingBefore,
            durationMissingAfterEstimates: missingAfter,
            boundedReadMissedArtwork: missedArtwork,
            containerMetadataComplete: containerComplete
        )
    }

    @Test("A remote reread never downloads the whole file just for a missing cover")
    func remoteMissingArtworkStaysBounded() {
        #expect(reason(missedArtwork: true) == nil)
        #expect(reason(missedArtwork: true, containerComplete: true) == nil)
    }

    @Test("A remote decoder-only file keeps its bounded duration estimate")
    func remoteDecoderFormatUsesEstimate() {
        // DTS: 有界读取读不出时长, 但按核心码率和文件大小估出来了。
        #expect(reason(decoder: true, missingBefore: true, missingAfter: false) == nil)
        // 估算也给不出时长: 只剩整首读这一条路。
        #expect(reason(decoder: true, missingBefore: true, missingAfter: true) == .durationUnavailable)
    }

    @Test("A remote file without any recoverable duration is still read completely")
    func remoteMissingDurationReadsCompleteFile() {
        #expect(reason(missingBefore: true, missingAfter: true) == .durationUnavailable)
    }

    @Test("An unknown signature only forces a complete read when nothing technical was recovered")
    func remoteUnknownSignature() {
        #expect(reason(unknown: true, technical: true) == nil)
        #expect(reason(unknown: true, technical: false) == .unrecognizedAudio)
    }

    @Test("A local file keeps the free complete read for every authoritative field")
    func localFileKeepsCompleteRead() {
        #expect(reason(local: true, decoder: true) == .decoderOnlyFormat)
        #expect(reason(local: true, unknown: true) == .unrecognizedAudio)
        #expect(reason(local: true, missingBefore: true) == .durationUnavailable)
        #expect(reason(local: true, missedArtwork: true) == .artworkOutsideBoundedWindows)
        #expect(reason(local: true, missedArtwork: true, containerComplete: true) == nil)
        #expect(reason(local: true) == nil)
    }

    @Test("Background maintenance never reads a complete file")
    func backgroundNeverReadsCompleteFile() {
        #expect(reason(explicit: false, local: true, decoder: true, unknown: true,
                       technical: false, missingBefore: true, missingAfter: true,
                       missedArtwork: true) == nil)
    }

    @Test("A Range-ignoring server downloads the whole file only for tail tags the head lacked")
    func tailCompleteFallback() {
        #expect(!DeferredEmbeddedArtworkPolicy.tailAllowsCompleteFileFallback(
            isExplicitReread: true, durationMissing: false, artistNeedsTail: false, headHasTitle: true
        ))
        #expect(DeferredEmbeddedArtworkPolicy.tailAllowsCompleteFileFallback(
            isExplicitReread: true, durationMissing: true, artistNeedsTail: false, headHasTitle: true
        ))
        #expect(DeferredEmbeddedArtworkPolicy.tailAllowsCompleteFileFallback(
            isExplicitReread: true, durationMissing: false, artistNeedsTail: true, headHasTitle: true
        ))
        #expect(DeferredEmbeddedArtworkPolicy.tailAllowsCompleteFileFallback(
            isExplicitReread: true, durationMissing: false, artistNeedsTail: false, headHasTitle: false
        ))
        #expect(!DeferredEmbeddedArtworkPolicy.tailAllowsCompleteFileFallback(
            isExplicitReread: false, durationMissing: true, artistNeedsTail: true, headHasTitle: false
        ))
    }

    // MARK: 有界读取没找到封面之后

    @Test("A fully inspected tag region means the file has no embedded cover")
    func completeRegionIsConclusive() {
        #expect(DeferredEmbeddedArtworkPolicy.stateAfterBoundedMiss(
            readsCompleteFile: false, containerMetadataComplete: false,
            headTagStructureComplete: true, tailUnreadable: false
        ) == .checkedNone)
        #expect(DeferredEmbeddedArtworkPolicy.stateAfterBoundedMiss(
            readsCompleteFile: false, containerMetadataComplete: true,
            headTagStructureComplete: false, tailUnreadable: true
        ) == .checkedNone)
        #expect(DeferredEmbeddedArtworkPolicy.stateAfterBoundedMiss(
            readsCompleteFile: true, containerMetadataComplete: false,
            headTagStructureComplete: false, tailUnreadable: true
        ) == .checkedNone)
    }

    @Test("A cover possibly beyond the bounded windows waits for the playback cache")
    func truncatedRegionAwaitsPlayback() {
        #expect(DeferredEmbeddedArtworkPolicy.stateAfterBoundedMiss(
            readsCompleteFile: false, containerMetadataComplete: false,
            headTagStructureComplete: false, tailUnreadable: false
        ) == .awaitingPlayback)
        #expect(DeferredEmbeddedArtworkPolicy.stateAfterBoundedMiss(
            readsCompleteFile: false, containerMetadataComplete: false,
            headTagStructureComplete: true, tailUnreadable: true
        ) == .awaitingPlayback)
    }

    @Test("Head structure evidence: declared lengths, the read ceiling and small files")
    func headStructureCompleteness() {
        let limit = 4 * 1024 * 1024
        // 没有长度声明可核对的格式不下结论。
        #expect(!DeferredEmbeddedArtworkPolicy.headTagStructureComplete(
            hasDeclaredStructure: false, parserWantsMoreBytes: false,
            inspectedByteCount: 1024, fileSize: 50_000_000, byteLimit: limit
        ))
        // ID3 声明比读到的长。
        #expect(!DeferredEmbeddedArtworkPolicy.headTagStructureComplete(
            hasDeclaredStructure: true, parserWantsMoreBytes: true,
            inspectedByteCount: limit, fileSize: 50_000_000, byteLimit: limit
        ))
        // 读满了上限、文件更长: 是被上限截住的。
        #expect(!DeferredEmbeddedArtworkPolicy.headTagStructureComplete(
            hasDeclaredStructure: true, parserWantsMoreBytes: false,
            inspectedByteCount: limit, fileSize: 50_000_000, byteLimit: limit
        ))
        // 标签区在上限以内就结束了。
        #expect(DeferredEmbeddedArtworkPolicy.headTagStructureComplete(
            hasDeclaredStructure: true, parserWantsMoreBytes: false,
            inspectedByteCount: 300_000, fileSize: 50_000_000, byteLimit: limit
        ))
        // 文件本身比上限小, 整个读到了。
        #expect(DeferredEmbeddedArtworkPolicy.headTagStructureComplete(
            hasDeclaredStructure: true, parserWantsMoreBytes: false,
            inspectedByteCount: 3_000_000, fileSize: 3_000_000, byteLimit: 2 * 1024 * 1024
        ))
    }

    // MARK: 露面读取

    @Test("Only display-deferred songs on file sources are read when they appear")
    func displayReadEligibility() {
        func reads(
            _ state: DeferredEmbeddedArtworkState,
            files: Bool = true,
            cue: Bool = false,
            strm: Bool = false,
            attempted: Bool = false,
            reading: Bool = false
        ) -> Bool {
            DeferredEmbeddedArtworkPolicy.readsOnDisplay(
                state: state, sourceReadsFiles: files, isCueTrack: cue,
                isStreamDescriptor: strm, attemptedThisSession: attempted, alreadyReading: reading
            )
        }
        #expect(reads(.awaitingDisplay))
        #expect(!reads(.awaitingPlayback))
        #expect(!reads(.checkedNone))
        #expect(!reads(.none))
        // 服务端曲库的封面走服务器接口, 不读音频。
        #expect(!reads(.awaitingDisplay, files: false))
        #expect(!reads(.awaitingDisplay, cue: true))
        #expect(!reads(.awaitingDisplay, strm: true))
        #expect(!reads(.awaitingDisplay, reading: true))
    }

    @Test("Scrolling back to a song does not read it again in the same session")
    func displayReadRetrySuppression() {
        #expect(!DeferredEmbeddedArtworkPolicy.readsOnDisplay(
            state: .awaitingDisplay, sourceReadsFiles: true, isCueTrack: false,
            isStreamDescriptor: false, attemptedThisSession: true, alreadyReading: false
        ))
    }

    @Test("Display reads stay off metered networks, Low Power Mode, a hot device and paused reading")
    func displayReadEnvironment() {
        #expect(DeferredEmbeddedArtworkPolicy.displayReadAllowed(
            onUnmeteredNetwork: true, lowPowerMode: false,
            thermalStateIsSeriousOrCritical: false, automaticReadingPaused: false
        ))
        #expect(!DeferredEmbeddedArtworkPolicy.displayReadAllowed(
            onUnmeteredNetwork: false, lowPowerMode: false,
            thermalStateIsSeriousOrCritical: false, automaticReadingPaused: false
        ))
        #expect(!DeferredEmbeddedArtworkPolicy.displayReadAllowed(
            onUnmeteredNetwork: true, lowPowerMode: true,
            thermalStateIsSeriousOrCritical: false, automaticReadingPaused: false
        ))
        #expect(!DeferredEmbeddedArtworkPolicy.displayReadAllowed(
            onUnmeteredNetwork: true, lowPowerMode: false,
            thermalStateIsSeriousOrCritical: true, automaticReadingPaused: false
        ))
        #expect(!DeferredEmbeddedArtworkPolicy.displayReadAllowed(
            onUnmeteredNetwork: true, lowPowerMode: false,
            thermalStateIsSeriousOrCritical: false, automaticReadingPaused: true
        ))
    }

    @Test("The display read stays within the bounded head")
    func displayReadBudget() {
        #expect(DeferredEmbeddedArtworkPolicy.displayInitialHeadByteCount
            <= DeferredEmbeddedArtworkPolicy.displayMaximumHeadByteCount)
        #expect(DeferredEmbeddedArtworkPolicy.displayMaximumHeadByteCount <= 2 * 1024 * 1024)
        #expect((1...2).contains(DeferredEmbeddedArtworkPolicy.displayReadConcurrency))
    }

    // MARK: 状态与播放缓存

    @Test("The persisted sets resolve to one state")
    func stateResolution() {
        func state(
            cover: Bool = false, supported: Bool = true,
            display: Bool = false, playback: Bool = false, closed: Bool = false
        ) -> DeferredEmbeddedArtworkState {
            DeferredEmbeddedArtworkPolicy.state(
                hasCover: cover, formatSupportsEmbeddedArtwork: supported,
                awaitingDisplay: display, awaitingPlayback: playback, artworkInspectionClosed: closed
            )
        }
        #expect(state(cover: true, display: true, playback: true, closed: true) == .none)
        #expect(state(supported: false, display: true) == .none)
        #expect(state(display: true, closed: true) == .awaitingDisplay)
        #expect(state(display: true, playback: true, closed: true) == .awaitingPlayback)
        #expect(state(closed: true) == .checkedNone)
        #expect(state() == .none)
    }

    @Test("The playback cache is consulted only for songs still waiting for a cover")
    func playbackCacheExtraction() {
        #expect(DeferredEmbeddedArtworkPolicy.extractsFromPlaybackCache(state: .awaitingPlayback))
        #expect(DeferredEmbeddedArtworkPolicy.extractsFromPlaybackCache(state: .awaitingDisplay))
        #expect(!DeferredEmbeddedArtworkPolicy.extractsFromPlaybackCache(state: .checkedNone))
        #expect(!DeferredEmbeddedArtworkPolicy.extractsFromPlaybackCache(state: .none))
    }

    // MARK: 歌旁边的图片

    @Test("Only an image named after the song beats the embedded cover")
    func songNamedImages() {
        let song = "/Music/Album/01 Song.flac"
        #expect(SourceImageCoverPrecedencePolicy.isSongNamedImage("/Music/Album/01 Song.WEBP", songFilePath: song))
        #expect(SourceImageCoverPrecedencePolicy.isSongNamedImage("/Music/Album/01 song-cover.png", songFilePath: song))
        // 文件夹封面只补缺, 不顶替内嵌封面。
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage("/Music/Album/cover.jpg", songFilePath: song))
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage("/Music/Album/Folder.jpg", songFilePath: song))
        // 别的文件夹里的同名图不算。
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage("/Music/Other/01 Song.jpg", songFilePath: song))
        // 封面库里存的内嵌封面、服务器地址和音频本身都不是。
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage(
            "embedded-" + String(repeating: "a", count: 64) + ".jpg", songFilePath: song
        ))
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage("https://nas.local/01 Song.jpg", songFilePath: song))
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage(song, songFilePath: song))
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage(nil, songFilePath: song))
        #expect(!SourceImageCoverPrecedencePolicy.isSongNamedImage("", songFilePath: song))
    }
}
