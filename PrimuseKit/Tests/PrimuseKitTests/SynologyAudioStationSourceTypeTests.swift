import Foundation
import Testing
@testable import PrimuseKit

/// 群晖 Audio Station 作为音乐源类型接进 App 时依赖的纯规则:类型能力、QuickConnect
/// 路由投影、地址识别、服务指纹与评分回写的边界。

/// 按 DSM `SYNO.API.Info` 的响应格式构造:装了 Audio Station 时报出它的 Info 接口。
private let audioStationInfoBody = """
{"data":{"SYNO.AudioStation.Info":{"maxVersion":6,"minVersion":1,"path":"AudioStation/info.cgi"}},"success":true}
"""

/// 同一个查询,套件没装或没启用时 DSM 仍然成功应答,只是一个接口都不报。
private let audioStationMissingBody = """
{"data":{},"success":true}
"""

struct SynologyAudioStationSourceTypeTests {
    @Test func audioStationIsAWholeLibraryServerSourceOnTheDSMPorts() {
        let type = MusicSourceType.synologyAudioStation
        #expect(type.category == .mediaServer)
        #expect(type.isServerLibrary)
        #expect(type.scansEntireLibrary)
        #expect(!type.continuesToDirectorySelectionAfterCreation)
        #expect(type.continuesToConnectionAfterCreation)
        #expect(!type.supportsFileDeletion)
        #expect(!type.supportsSidecarWriting)
        #expect(!type.supportsEmbeddedMetadataBackfill)
        #expect(type.supportsRangeStreaming)
        #expect(type.supports2FA)
        #expect(type.requiresHost)
        #expect(type.requiresCredentials)
        #expect(type.supportsVendorRemoteAccess)
        #expect(type.usesHTTPTransport)
        #expect(type.supportsAdaptiveConnections)
        #expect(type.supportsEndpointSpecificPath)
        #expect(type.defaultSSL)
        #expect(type.defaultPort == 5001)
        #expect(type.defaultPort(useSsl: true) == 5001)
        #expect(type.defaultPort(useSsl: false) == 5000)
        #expect(type.catalogDeletionAuthority == .authoritative)
        #expect(!type.usesPagedCatalogStaging)
        #expect(!type.isAwaitingPublicAPI)
        #expect(MusicSourceType.catalogCases.contains(type))
    }

    @Test func onlyAudioStationGainsTheConnectionStepWithoutDirectories() {
        for type in MusicSourceType.allCases where type != .synologyAudioStation {
            #expect(type.continuesToConnectionAfterCreation == type.continuesToDirectorySelectionAfterCreation)
        }
        #expect(MusicSourceType.allCases.filter(\.usesSynologyConnectionMode) == [.synology, .synologyAudioStation])
        #expect(MusicSourceType.allCases.filter(\.supportsVendorRemoteAccess)
            == [.synology, .fnMusic, .synologyAudioStation])
    }

    @Test func eachRouteProjectsItsOwnSynologyConnectionMode() {
        let source = MusicSource(
            id: "audio-station",
            name: "NAS",
            type: .synologyAudioStation,
            connectionConfiguration: SourceConnectionConfiguration(
                localEndpoint: SourceConnectionEndpoint(
                    host: "192.168.1.8",
                    port: 5001,
                    useSsl: true,
                    pathPrefix: "/nas"
                ),
                remoteAccessMode: .vendor,
                vendorIdentifier: "mynas"
            ),
            username: "user",
            basePath: "/nas"
        )
        let candidates = source.connectionCandidates
        #expect(candidates.map(\.kind) == [.localAddress, .vendorRemote])

        let local = source.applyingConnectionCandidate(candidates[0])
        #expect(local.effectiveSynologyConnectionMode == .address)
        #expect(local.host == "192.168.1.8")
        #expect(local.port == 5001)
        #expect(local.basePath == "/nas")

        let relay = source.applyingConnectionCandidate(candidates[1])
        #expect(relay.effectiveSynologyConnectionMode == .quickConnect)
        #expect(relay.host == "mynas")
        #expect(relay.port == 5001)
        #expect(relay.useSsl)
        // QuickConnect 解析出的是 DSM 根地址,直连端点的反代前缀不跟过去。
        #expect(relay.basePath == nil)
    }

    @Test func legacyQuickConnectRecordKeepsItsVendorRoute() {
        let source = MusicSource(
            name: "NAS",
            type: .synologyAudioStation,
            host: "mynas",
            synologyConnectionMode: .quickConnect
        )
        let configuration = source.effectiveConnectionConfiguration
        #expect(configuration?.remoteAccessMode == .vendor)
        #expect(configuration?.vendorIdentifier == "mynas")
        #expect(source.connectionCandidates.map(\.kind) == [.vendorRemote])
    }

    @Test func addressFieldRecognisesQuickConnectIDs() {
        #expect(SourceAddressInputPolicy.interpret(
            "https://quickconnect.to/mynas",
            sourceType: .synologyAudioStation
        ) == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))
        #expect(SourceAddressInputPolicy.interpret(
            "mynas.quickconnect.to",
            sourceType: .synologyAudioStation
        ) == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))
        guard case .endpoint = SourceAddressInputPolicy.interpret(
            "192.168.1.8",
            sourceType: .synologyAudioStation
        ) else {
            Issue.record("a LAN address must stay an endpoint")
            return
        }
    }

    /// 单地址框的归位与回显和群晖直连一致:内网地址 + QuickConnect ID 各占一格,
    /// 存下来再读回去不变,地址没动就不重新探测。
    @Test func addressFormPlacesLANAndQuickConnectLikeTheFileStationSource() {
        let reading = SourceAddressFormPolicy.read(
            [
                SourceAddressFormPolicy.AddressDraft(address: "192.168.1.30"),
                SourceAddressFormPolicy.AddressDraft(address: "mynas"),
            ],
            sourceType: .synologyAudioStation
        )
        #expect(reading.placement.slots == [.local, .vendor])
        #expect(reading.placement.usesVendorRemoteAccess)
        #expect(reading.isSubmittable)

        let configuration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "192.168.1.30", port: 5000, useSsl: false),
            remoteAccessMode: .vendor,
            vendorIdentifier: "mynas"
        )
        let drafts = SourceAddressFormPolicy.drafts(for: configuration, sourceType: .synologyAudioStation)
        #expect(drafts.map(\.address) == ["http://192.168.1.30:5000", "mynas"])
        #expect(SourceAddressFormPolicy.read(drafts, sourceType: .synologyAudioStation).placement.slots
            == [.local, .vendor])
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: drafts, baseline: drafts) == false)
    }

    @Test func addressWithoutPortTriesTheDSMPorts() {
        guard case .endpoint(let input) = SourceAddressInputPolicy.interpret(
            "192.168.1.30",
            sourceType: .synologyAudioStation
        ) else {
            Issue.record("a LAN address must stay an endpoint")
            return
        }
        let ports = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .synologyAudioStation)
            .map(\.port)
        #expect(ports.contains(5001))
        #expect(ports.contains(5000))
    }

    @Test func fingerprintAsksForTheAudioStationInterfaceWithoutCredentials() {
        guard let request = SourceServiceFingerprint.probeRequest(for: .synologyAudioStation) else {
            Issue.record("no probe request for Audio Station")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/webapi/query.cgi")
        let values = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value) })
        #expect(values["api"] == "SYNO.API.Info")
        #expect(values["method"] == "query")
        #expect(values["query"] == "SYNO.AudioStation.Info")
        #expect(values.keys.contains("account") == false)
        #expect(values.keys.contains("passwd") == false)
        #expect(values.keys.contains("_sid") == false)
    }

    @Test func fingerprintConfirmsOnlyAnInstalledAudioStation() {
        let installed = SourceServiceFingerprint.ProbeResponse(statusCode: 200, bodyPrefix: audioStationInfoBody)
        #expect(SourceServiceFingerprint.evaluate(installed, sourceType: .synologyAudioStation) == .confirmed)
        // 装了 Audio Station 的 DSM 仍然是 DSM,但反过来不成立:群晖直连只认 Auth。
        #expect(SourceServiceFingerprint.evaluate(installed, sourceType: .synology) == .responded(statusCode: 200))

        let missing = SourceServiceFingerprint.ProbeResponse(statusCode: 200, bodyPrefix: audioStationMissingBody)
        #expect(SourceServiceFingerprint.evaluate(missing, sourceType: .synologyAudioStation)
            == .responded(statusCode: 200))

        let notFound = SourceServiceFingerprint.ProbeResponse(statusCode: 404, bodyPrefix: "<html></html>")
        #expect(SourceServiceFingerprint.evaluate(notFound, sourceType: .synologyAudioStation)
            == .responded(statusCode: 404))
    }

    @Test func ratingWritebackCoversNavidromeAndAudioStationOnly() {
        for type in MusicSourceType.allCases {
            #expect(ServerRatingWritebackPolicy.supports(type) == [.navidrome, .synologyAudioStation].contains(type))
        }
        #expect(ServerRatingWritebackPolicy.songID(
            fromConnectorPath: "/songs/music_6906.flac",
            sourceType: .synologyAudioStation
        ) == "music_6906")
        #expect(ServerRatingWritebackPolicy.songID(
            fromConnectorPath: "/songs/music_v_1111.mp3",
            sourceType: .synologyAudioStation
        ) == "music_v_1111")
        // 歌单里尚未入库的 NAS 路径、别的源的路径都不是可评分的目录曲目。
        #expect(ServerRatingWritebackPolicy.songID(
            fromConnectorPath: "/songs/music_/volume1/music/a.flac",
            sourceType: .synologyAudioStation
        ) == nil)
        #expect(ServerRatingWritebackPolicy.songID(
            fromConnectorPath: "/items/abc.flac",
            sourceType: .synologyAudioStation
        ) == nil)
        // Navidrome 的解析与收藏回写同一份规则,行为不变。
        #expect(ServerRatingWritebackPolicy.songID(
            fromConnectorPath: "/songs/navidrome-song.flac",
            sourceType: .navidrome
        ) == ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: "/songs/navidrome-song.flac",
            sourceType: .navidrome
        ))
        #expect(ServerRatingWritebackPolicy.songID(
            fromConnectorPath: "/songs/music_6906.flac",
            sourceType: .subsonic
        ) == nil)
    }

    @Test func audioStationIsNotAFavoriteOrSharingSource() {
        #expect(!ServerFavoriteWritebackPolicy.supports(.synologyAudioStation))
        #expect(!ServerMediaShareTargetPolicy.supports(.synologyAudioStation))
        #expect(MusicSourceType.synologyAudioStation.serverListeningStatsCapability == .unavailable)
    }

    @Test func rangeReadsStayDemandDrivenLikeTheOtherDSMSource() {
        for type in [MusicSourceType.synology, .synologyAudioStation] {
            #expect(RangeStreamingPrefetchPolicy.aheadCount(for: type, defaultValue: 5) == 1)
            #expect(!RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: type))
            #expect(RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: type))
        }
    }

    @Test func serverLyricsAreAuthoritativeForAudioStation() {
        #expect(LyricsAuthoritativeSourcePolicy.supportsServerDocument(.synologyAudioStation))
    }
}
