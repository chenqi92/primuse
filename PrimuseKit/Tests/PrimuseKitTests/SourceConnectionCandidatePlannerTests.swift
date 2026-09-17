import Foundation
import Testing
@testable import PrimuseKit

private func plan(
    _ address: String,
    _ sourceType: MusicSourceType,
    manualPort: Int? = nil,
    manualUseSsl: Bool? = nil
) -> [SourceConnectionCandidatePlanner.Candidate] {
    guard case let .endpoint(input) = SourceAddressInputPolicy.interpret(address, sourceType: sourceType) else {
        Issue.record("\(address) did not read back as an endpoint")
        return []
    }
    return SourceConnectionCandidatePlanner.candidates(
        for: input,
        sourceType: sourceType,
        manualPort: manualPort,
        manualUseSsl: manualUseSsl
    )
}

private func identifiers(_ candidates: [SourceConnectionCandidatePlanner.Candidate]) -> [String] {
    candidates.map(\.id)
}

// MARK: - 写全了就不猜

@Test func plannerKeepsASingleCandidateWhenSchemeAndPortAreBothWritten() {
    let candidates = plan("https://emby.example.com:8920", .emby)
    #expect(identifiers(candidates) == ["ssl:8920"])
    #expect(candidates.first?.origin == .explicitAddress)
}

// MARK: - 地址栏语义:没写端口就是 80 / 443

@Test func plannerTriesSchemeDefaultPortBeforeServicePort() {
    // 这就是「反代后面的 Emby 被连到 8096」那个 bug 的修法。
    #expect(identifiers(plan("https://emby.example.com", .emby)) == ["ssl:443", "ssl:8920"])
    #expect(identifiers(plan("http://nas.lan", .emby)) == ["plain:80", "plain:8096"])
}

// MARK: - 写了端口没写协议

@Test func plannerOrdersProtocolsByPortHint() {
    #expect(identifiers(plan("emby.example.com:443", .emby)) == ["ssl:443", "plain:443"])
    #expect(identifiers(plan("emby.example.com:8443", .emby)) == ["ssl:8443", "plain:8443"])
    #expect(identifiers(plan("192.168.1.10:8920", .emby)) == ["ssl:8920", "plain:8920"])
    #expect(identifiers(plan("emby.example.com:80", .emby)) == ["plain:80", "ssl:80"])
    #expect(identifiers(plan("emby.example.com:8096", .emby)) == ["plain:8096", "ssl:8096"])
}

@Test func plannerFallsBackToHostClassWhenThePortSaysNothing() {
    #expect(identifiers(plan("192.168.1.10:9000", .emby)) == ["plain:9000", "ssl:9000"])
    #expect(identifiers(plan("emby.example.com:9000", .emby)) == ["ssl:9000", "plain:9000"])
    #expect(identifiers(plan("nas.tailnet.ts.net:9000", .emby)) == ["plain:9000", "ssl:9000"])
}

// MARK: - 什么都没写

@Test func plannerPrefersCleartextServicePortOnPrivateHosts() {
    #expect(
        identifiers(plan("192.168.1.10", .emby)) == ["plain:8096", "ssl:8920", "ssl:443", "plain:80"]
    )
    #expect(
        identifiers(plan("localhost", .jellyfin)) == ["plain:8096", "ssl:8920", "ssl:443", "plain:80"]
    )
    #expect(
        identifiers(plan("100.64.0.7", .synology)) == ["plain:5000", "ssl:5001", "ssl:443", "plain:80"]
    )
}

@Test func plannerPrefersHTTPS443OnPublicHosts() {
    #expect(
        identifiers(plan("emby.example.com", .emby)) == ["ssl:443", "ssl:8920", "plain:8096", "plain:80"]
    )
    #expect(
        identifiers(plan("nav.example.com", .navidrome)) == ["ssl:443", "ssl:4533", "plain:4533", "plain:80"]
    )
}

// MARK: - 会塌缩的服务端口

@Test func plannerCollapsesWebDAVAndS3ToTwoCandidates() {
    // 服务端口本身就是 80 / 443,四条规则里两条是重复的。
    #expect(identifiers(plan("192.168.1.10", .webdav)) == ["plain:80", "ssl:443"])
    #expect(identifiers(plan("dav.example.com", .webdav)) == ["ssl:443", "plain:80"])
    #expect(identifiers(plan("s3.example.com", .s3)) == ["ssl:443", "plain:80"])
}

@Test func plannerHandlesPlexSharingOnePortAcrossBothProtocols() {
    #expect(
        identifiers(plan("192.168.1.10", .plex)) == ["plain:32400", "ssl:32400", "ssl:443", "plain:80"]
    )
    // 32400 同时是两种协议的服务端口,所以它给不出协议提示,只能按主机分类排。
    #expect(identifiers(plan("192.168.1.10:32400", .plex)) == ["plain:32400", "ssl:32400"])
    #expect(identifiers(plan("plex.example.com:32400", .plex)) == ["ssl:32400", "plain:32400"])
}

// MARK: - 手动约束

@Test func plannerTreatsManualPortAsAHardConstraint() {
    let candidates = plan("emby.example.com", .emby, manualPort: 8096)
    #expect(identifiers(candidates) == ["plain:8096", "ssl:8096"])
    #expect(candidates.allSatisfy { $0.origin == .manualOverride })
}

@Test func plannerTreatsManualProtocolAsAHardConstraint() {
    #expect(identifiers(plan("emby.example.com", .emby, manualUseSsl: true)) == ["ssl:443", "ssl:8920"])
    #expect(identifiers(plan("emby.example.com", .emby, manualUseSsl: false)) == ["plain:80", "plain:8096"])
}

@Test func plannerLetsTheAddressWinOverManualEntries() {
    // 地址里写死的协议和端口比高级选项里残留的旧值更贴近用户当下的意图。
    let candidates = plan("https://emby.example.com:9090", .emby, manualPort: 8096, manualUseSsl: false)
    #expect(identifiers(candidates) == ["ssl:9090"])
}

@Test func plannerIgnoresAnOutOfRangeManualPort() {
    #expect(identifiers(plan("emby.example.com", .emby, manualPort: 0)) == ["ssl:443", "ssl:8920", "plain:8096", "plain:80"])
}

// MARK: - 非 HTTP 类型

@Test func plannerGivesNonHTTPTypesExactlyOneCandidate() {
    let smb = plan("nas.local", .smb)
    #expect(identifiers(smb) == ["plain:445"])
    #expect(smb.first?.origin == .fixedProtocolPort)
    #expect(smb.first?.useSsl == false)

    #expect(identifiers(plan("smb://nas.local/music", .smb)) == ["plain:445"])
    #expect(identifiers(plan("nas.local:4450", .smb)) == ["plain:4450"])
    #expect(identifiers(plan("nas.local", .sftp)) == ["plain:22"])
    #expect(identifiers(plan("nas.local", .nfs)) == ["plain:2049"])
    #expect(identifiers(plan("nas.local", .ftp, manualPort: 2121)) == ["plain:2121"])
}

@Test func plannerUsesTheImplicitTLSPortForFTPS() {
    let candidates = plan("ftps://nas.local", .ftp)
    #expect(candidates.first?.useSsl == true)
    #expect(candidates.first?.port == 21)
}

// MARK: - 总量上限

@Test func plannerNeverExceedsTheCandidateCap() {
    let addresses = ["192.168.1.10", "emby.example.com", "100.64.0.7", "localhost", "[fd00::1]"]
    for sourceType in MusicSourceType.allCases where sourceType.requiresHost {
        for address in addresses {
            guard case let .endpoint(input) = SourceAddressInputPolicy.interpret(
                address,
                sourceType: sourceType,
                treatDotlessTokenAsHostname: true
            ) else {
                continue
            }
            let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: sourceType)
            #expect(candidates.isEmpty == false)
            #expect(candidates.count <= SourceConnectionCandidatePlanner.maximumCandidateCount)
            #expect(Set(candidates.map(\.id)).count == candidates.count)
        }
    }
}
