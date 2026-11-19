import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source card presentation")
struct SourceCardPresentationPolicyTests {
    private func source(
        _ id: String,
        _ type: MusicSourceType,
        host: String? = nil,
        username: String? = nil
    ) -> MusicSource {
        MusicSource(id: id, name: id, type: type, host: host, username: username)
    }

    @Test("Sources of one type sit together, in first-seen order, keeping their own order")
    func sameTypeTogether() {
        let ordered = SourceCardPresentationPolicy.keepingSameTypeTogether([
            source("a", .synology), source("b", .qnap), source("c", .synology),
            source("d", .ugreen), source("e", .qnap),
        ])
        #expect(ordered.map(\.id) == ["a", "c", "b", "e", "d"])
    }

    @Test("Order is unchanged when every type appears once")
    func distinctTypesUnchanged() {
        let ordered = SourceCardPresentationPolicy.keepingSameTypeTogether([
            source("a", .smb), source("b", .webdav), source("c", .nfs),
        ])
        #expect(ordered.map(\.id) == ["a", "b", "c"])
    }

    @Test("Account is shown only where type and address both repeat")
    func accountDisambiguation() {
        let ids = SourceCardPresentationPolicy.sourceIDsShowingAccount([
            source("home-admin", .synology, host: "192.168.1.10", username: "admin"),
            source("home-kid", .synology, host: "192.168.1.10", username: "kid"),
            source("office", .synology, host: "10.0.0.5", username: "admin"),
            source("smb", .smb, host: "192.168.1.10"),
            source("pan-1", .baiduPan),
            source("pan-2", .baiduPan),
        ])
        #expect(ids == ["home-admin", "home-kid", "pan-1", "pan-2"])
    }

    @Test("Displayed route prefers the active one, then the last that worked, then the chosen one")
    func displayedRoute() {
        let local = SourceConnectionCandidate(
            kind: .localAddress,
            endpoint: SourceConnectionEndpoint(host: "192.168.1.10", port: 5001, useSsl: true)
        )
        let remote = SourceConnectionCandidate(kind: .vendorRemote, vendorIdentifier: "home-nas")
        let candidates = [local, remote]

        #expect(SourceCardPresentationPolicy.displayedRoute(
            candidates: candidates, active: .vendorRemote, lastSuccessful: .localAddress, selected: nil
        )?.kind == .vendorRemote)
        #expect(SourceCardPresentationPolicy.displayedRoute(
            candidates: candidates, active: nil, lastSuccessful: .vendorRemote, selected: .localAddress
        )?.kind == .vendorRemote)
        #expect(SourceCardPresentationPolicy.displayedRoute(
            candidates: candidates, active: nil, lastSuccessful: nil, selected: .vendorRemote
        )?.kind == .vendorRemote)
        #expect(SourceCardPresentationPolicy.displayedRoute(
            candidates: candidates, active: .publicAddress, lastSuccessful: nil, selected: nil
        )?.kind == .localAddress)
        #expect(SourceCardPresentationPolicy.displayedRoute(
            candidates: [], active: .localAddress, lastSuccessful: nil, selected: nil
        ) == nil)
    }
}
