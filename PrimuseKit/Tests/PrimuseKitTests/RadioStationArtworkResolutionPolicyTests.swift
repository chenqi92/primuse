import Foundation
import Testing
@testable import PrimuseKit

@Suite("Radio station artwork resolution")
struct RadioStationArtworkResolutionPolicyTests {
    @Test("A server reference is available without inline bytes")
    func referenceOnlyPlan() {
        let station = makeStation(
            logoFileName: "/Items/station/Images/Primary",
            sourceID: "jellyfin-main",
            sourcePlaybackPath: "Audio/stream/42"
        )

        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)

        #expect(plan.candidates.count == 1)
        guard case .cachedOrSource(let request) = plan.candidates.first else {
            Issue.record("Expected a cached/source candidate")
            return
        }
        #expect(request.coverReference == "/Items/station/Images/Primary")
        #expect(request.songID == "radio:station")
    }

    @Test("Inline bytes are preferred and a decode failure advances to the reference")
    func inlinePriorityAndFallback() async {
        let station = makeStation(
            logoData: Data([0x01, 0x02]),
            logoFileName: "station-cover.jpg"
        )
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)
        var attempts: [RadioStationArtworkCandidate] = []

        let resolved: RadioStationArtworkResolution<String>? = await RadioStationArtworkResolver
            .resolve(plan: plan) { candidate in
            attempts.append(candidate)
            switch candidate {
            case .inline:
                return nil
            case .cachedOrSource:
                return "reference-image"
            }
        }

        #expect(attempts.count == 2)
        if case .inline = attempts.first {
            // Expected priority.
        } else {
            Issue.record("Inline artwork was not attempted first")
        }
        #expect(resolved?.value == "reference-image")
    }

    @Test("A successful inline image does not request the remote fallback")
    func successfulInlineStopsResolution() async {
        let station = makeStation(
            logoData: Data([0x0A]),
            logoFileName: "fallback.jpg"
        )
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)
        var attempts = 0

        let resolved = await RadioStationArtworkResolver.resolve(plan: plan) { candidate in
            attempts += 1
            if case .inline = candidate { return "inline-image" }
            return "unexpected-remote-image"
        }

        #expect(attempts == 1)
        #expect(resolved?.value == "inline-image")
    }

    @Test("A station without artwork resolves to the placeholder")
    func placeholderOnlyPlan() async {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: makeStation())
        let resolved: RadioStationArtworkResolution<String>? = await RadioStationArtworkResolver.resolve(
            plan: plan,
            using: { _ in "unexpected" }
        )

        #expect(plan.usesPlaceholderOnly)
        #expect(resolved == nil)
    }

    @Test("Server source provenance is preserved exactly")
    func serverMirrorProvenance() {
        let station = makeStation(
            logoFileName: "Items/7/Images/Primary",
            streamFormat: .flac,
            sourceID: "navidrome-home",
            sourcePlaybackPath: "rest/stream?id=7"
        )
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)

        guard case .cachedOrSource(let request) = plan.candidates.first else {
            Issue.record("Expected a cached/source candidate")
            return
        }
        #expect(request.sourceID == "navidrome-home")
        #expect(request.filePath == "rest/stream?id=7")
        #expect(request.fileFormat == .flac)
        #expect(request.songID == station.playbackSong.id)
    }

    @Test("A plain URL station does not synthesize source ownership")
    func plainURLProvenance() {
        let station = makeStation(logoFileName: "https://cdn.example.test/logo.png")
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)

        guard case .cachedOrSource(let request) = plan.candidates.first else {
            Issue.record("Expected a cached/source candidate")
            return
        }
        #expect(request.sourceID == nil)
        #expect(request.filePath == station.streamURL)
        #expect(station.playbackSong.sourceID == RadioStation.playbackSourceID)
    }

    @Test("Late and cancelled results cannot replace a reused cell")
    func staleResultProtection() {
        let first = RadioStationArtworkResolutionPolicy.makePlan(for: makeStation(
            id: "first",
            logoFileName: "first.jpg"
        ))
        let second = RadioStationArtworkResolutionPolicy.makePlan(for: makeStation(
            id: "second",
            logoFileName: "second.jpg"
        ))

        #expect(first.identity != second.identity)
        #expect(!RadioStationArtworkResultPolicy.shouldApply(
            completedIdentity: first.identity,
            displayedIdentity: second.identity,
            isCancelled: false
        ))
        #expect(!RadioStationArtworkResultPolicy.shouldApply(
            completedIdentity: second.identity,
            displayedIdentity: second.identity,
            isCancelled: true
        ))
        #expect(RadioStationArtworkResultPolicy.shouldApply(
            completedIdentity: second.identity,
            displayedIdentity: second.identity,
            isCancelled: false
        ))
    }

    @Test("Cancellation after a late loader response discards the result")
    func cancelledLoadDiscardsLateResponse() async {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: makeStation(
            logoFileName: "late.jpg"
        ))
        let loader = ControlledRadioArtworkLoader()
        let task = Task<RadioStationArtworkResolution<String>?, Never> {
            await RadioStationArtworkResolver.resolve(plan: plan) { _ in
                await loader.load()
            }
        }

        await loader.waitUntilStarted()
        task.cancel()
        await loader.finish(with: "late-image")

        #expect(await task.value == nil)
    }

    @Test("Canonical cache identity is separate from request deduplication")
    func canonicalCacheIdentity() {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: makeStation(
            logoFileName: "station-cover.jpg",
            sourceID: "server",
            sourcePlaybackPath: "stream/station"
        ))

        guard case .cachedOrSource(let request) = plan.candidates.first else {
            Issue.record("Expected a cached/source candidate")
            return
        }
        #expect(request.songID == "radio:station")
        #expect(request.cacheDiscriminator != request.songID)
        #expect(request.cacheDiscriminator.contains(request.songID))
    }

    @Test("Matching cache publications and invalidations advance visible artwork")
    func cacheRevisionPolicy() {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: makeStation(
            logoFileName: "station-cover.jpg"
        ))
        guard case .cachedOrSource(let request) = plan.candidates.first else {
            Issue.record("Expected a cached/source candidate")
            return
        }

        #expect(RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterCaching(
            cachedSongID: request.songID,
            request: request,
            hasResolvedImage: false
        ))
        #expect(!RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterCaching(
            cachedSongID: request.songID,
            request: request,
            hasResolvedImage: true
        ))
        #expect(RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterInvalidation(
            invalidatesAll: false,
            invalidatedTokens: [request.coverReference],
            request: request
        ))
        #expect(RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterInvalidation(
            invalidatesAll: true,
            invalidatedTokens: [],
            request: request
        ))
        #expect(!RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterInvalidation(
            invalidatesAll: false,
            invalidatedTokens: ["another-song"],
            request: request
        ))
    }

    @Test("Every artwork input participates in load and cache identity")
    func completeIdentity() {
        let original = makeStation(
            logoData: Data([0x01]),
            logoFileName: "cover.jpg",
            sourceID: "source-a",
            sourcePlaybackPath: "path-a"
        )
        let originalPlan = RadioStationArtworkResolutionPolicy.makePlan(for: original)
        let variants = [
            makeStation(
                logoData: Data([0x02]),
                logoFileName: "cover.jpg",
                sourceID: "source-a",
                sourcePlaybackPath: "path-a"
            ),
            makeStation(
                logoData: Data([0x01]),
                logoFileName: "other.jpg",
                sourceID: "source-a",
                sourcePlaybackPath: "path-a"
            ),
            makeStation(
                logoData: Data([0x01]),
                logoFileName: "cover.jpg",
                sourceID: "source-b",
                sourcePlaybackPath: "path-a"
            ),
            makeStation(
                logoData: Data([0x01]),
                logoFileName: "cover.jpg",
                sourceID: "source-a",
                sourcePlaybackPath: "path-b"
            ),
        ]

        for variant in variants {
            let variantPlan = RadioStationArtworkResolutionPolicy.makePlan(for: variant)
            #expect(variantPlan.identity != originalPlan.identity)
        }

        guard case .cachedOrSource(let originalRequest) = originalPlan.candidates.last,
              case .cachedOrSource(let changedRequest) = RadioStationArtworkResolutionPolicy
                .makePlan(for: variants[1]).candidates.last else {
            Issue.record("Expected cached/source candidates")
            return
        }
        #expect(originalRequest.cacheDiscriminator != changedRequest.cacheDiscriminator)
    }

    @Test("The radio wall fits square artwork at iPhone and iPad widths")
    func adaptiveViewportLayout() {
        let layout = RadioStationArtworkGridLayout()

        let iPhone = layout.measure(containerWidth: 393)
        let iPadPortrait = layout.measure(containerWidth: 834)
        let iPadLandscape = layout.measure(containerWidth: 1_366)

        #expect(iPhone.columnCount == 2)
        #expect(iPhone.itemWidth == 169.5)
        #expect(iPadPortrait.columnCount == 4)
        #expect(iPadPortrait.itemWidth == 188)
        #expect(iPadLandscape.columnCount == 8)
        #expect(iPadLandscape.itemWidth == 153.5)
        #expect(iPhone.itemWidth >= layout.minimumItemWidth)
        #expect(iPhone.itemWidth <= layout.maximumItemWidth)
        #expect(iPadPortrait.itemWidth >= layout.minimumItemWidth)
        #expect(iPadPortrait.itemWidth <= layout.maximumItemWidth)
        #expect(iPadLandscape.itemWidth >= layout.minimumItemWidth)
        #expect(iPadLandscape.itemWidth <= layout.maximumItemWidth)
    }

    // MARK: - 自动发现来的远程台标

    @Test("没有自有台标时才用自动发现的那张")
    func remoteLogoFillsInOnlyWhenNothingElseExists() {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(
            for: makeStation(remoteLogoURL: "https://cdn.example.test/logo.png")
        )
        #expect(plan.candidates.count == 1)
        guard case .cachedOrSource(let request) = plan.candidates[0] else {
            Issue.record("Expected the remote candidate")
            return
        }
        #expect(request.coverReference == "https://cdn.example.test/logo.png")
    }

    /// 这个地址属于公网，不属于任何音乐源。带上 sourceID 会让加载层先去问
    /// 一个不存在的连接器，而带上 filePath 会让它去翻不存在的本地缓存文件。
    /// 这个地址属于公网，不属于任何音乐源。带上 sourceID 会让加载层先去问一个
    /// 不存在的连接器，带上 filePath 会让它去翻不存在的本地缓存文件。
    @Test("远程台标候选不携带音乐源归属")
    func remoteLogoCandidateHasNoSourceOwnership() {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(
            for: makeStation(remoteLogoURL: "https://cdn.example.test/logo.png")
        )
        guard case .cachedOrSource(let remote) = plan.candidates.last else {
            Issue.record("Expected a remote candidate")
            return
        }
        #expect(remote.coverReference == "https://cdn.example.test/logo.png")
        #expect(remote.sourceID == nil)
        #expect(remote.filePath == nil)
    }

    /// 用户自己选的图必须是终点：加载失败就显示占位符，绝不能悄悄换成一张
    /// 网上抓来的图 —— 那会让用户以为自己的台标被顶掉了。
    @Test("电台已有自己的台标时，远程台标彻底退场")
    func ownedLogoSuppressesRemoteCandidate() {
        let withInline = makeStation(
            logoData: Data([0x01, 0x02]),
            remoteLogoURL: "https://cdn.example.test/logo.png"
        )
        #expect(RadioStationArtworkResolutionPolicy.makePlan(for: withInline).candidates.count == 1)

        let withFileName = makeStation(
            logoFileName: "station-cover.jpg",
            remoteLogoURL: "https://cdn.example.test/logo.png"
        )
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: withFileName)
        #expect(plan.candidates.count == 1)
        guard case .cachedOrSource(let request) = plan.candidates[0] else {
            Issue.record("Expected the owned reference to be the only candidate")
            return
        }
        #expect(request.coverReference == "station-cover.jpg")
    }

    /// 两者过去共用电台的播放 songID，而封面缓存按键寻址到同一个文件 ——
    /// 远程台标被加载一次就会把用户的图从磁盘顶掉。
    @Test("远程台标的缓存键与用户台标分开")
    func remoteLogoUsesSeparateCacheKey() {
        let station = makeStation(remoteLogoURL: "https://cdn.example.test/logo.png")
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)
        guard case .cachedOrSource(let remote) = plan.candidates.last else {
            Issue.record("Expected a remote candidate")
            return
        }
        #expect(remote.songID != station.playbackSong.id)
        #expect(remote.songID == RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(
            for: station.id
        ))
    }

    @Test("坏地址不会变成候选")
    func rejectsInvalidRemoteLogo() {
        for bad in ["0", "not a url", "ftp://a.com/l.png", "https://user:pw@a.com/l.png"] {
            let plan = RadioStationArtworkResolutionPolicy.makePlan(
                for: makeStation(remoteLogoURL: bad)
            )
            #expect(plan.usesPlaceholderOnly, "\(bad) should not become a candidate")
        }
    }

    @Test("没有本地台标时，播放用的 Song 直接指向远程台标")
    func playbackSongFallsBackToRemoteLogo() {
        let station = makeStation(remoteLogoURL: "https://cdn.example.test/logo.png")
        #expect(station.playbackSong.coverArtFileName == "https://cdn.example.test/logo.png")

        let withLocal = makeStation(
            logoFileName: "station-cover.jpg",
            remoteLogoURL: "https://cdn.example.test/logo.png"
        )
        #expect(withLocal.playbackSong.coverArtFileName == "station-cover.jpg")
    }

    private func makeStation(
        id: String = "station",
        logoData: Data? = nil,
        logoFileName: String? = nil,
        streamFormat: RadioStreamFormat = .aac,
        sourceID: String? = nil,
        sourcePlaybackPath: String? = nil,
        remoteLogoURL: String? = nil
    ) -> RadioStation {
        RadioStation(
            id: id,
            name: "Radio",
            streamURL: "https://radio.example.test/live",
            logoData: logoData,
            logoFileName: logoFileName,
            streamFormat: streamFormat,
            sourceID: sourceID,
            serverStationID: sourceID == nil ? nil : "server-station",
            sourceName: sourceID == nil ? nil : "Server",
            sourcePlaybackPath: sourcePlaybackPath,
            remoteLogoURL: remoteLogoURL,
            remoteLogoSource: remoteLogoURL == nil ? nil : .icyHeader
        )
    }
}

private actor ControlledRadioArtworkLoader {
    private var loadContinuation: CheckedContinuation<String?, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func load() async -> String? {
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
            let waiters = startContinuations
            startContinuations.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilStarted() async {
        if loadContinuation != nil { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func finish(with value: String?) {
        loadContinuation?.resume(returning: value)
        loadContinuation = nil
    }
}
