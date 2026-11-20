import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source connection route labels")
struct SourceConnectionRouteLabelTests {
    private let local = SourceConnectionCandidate(
        kind: .localAddress,
        endpoint: SourceConnectionEndpoint(host: "192.168.1.10", port: 5001, useSsl: true)
    )
    private let remote = SourceConnectionCandidate(
        kind: .publicAddress,
        endpoint: SourceConnectionEndpoint(host: "nas.example.com", port: 443, useSsl: true)
    )
    private let extra = SourceConnectionCandidate(
        kind: .alternative(UUID()),
        endpoint: SourceConnectionEndpoint(host: "100.64.0.2", port: 5001, useSsl: true)
    )

    @Test("Local and public addresses default to LAN and Internet")
    func defaults() {
        #expect(SourceConnectionRouteNamingPolicy.defaultLabel(for: .localAddress) == .lan)
        #expect(SourceConnectionRouteNamingPolicy.defaultLabel(for: .publicAddress) == .internet)
        #expect(SourceConnectionRouteNamingPolicy.defaultLabel(for: .vendorRemote) == nil)
        #expect(SourceConnectionRouteNamingPolicy.defaultLabel(for: extra.kind) == nil)
        #expect(SourceConnectionRouteNamingPolicy.label(for: .localAddress, custom: .homeCellar) == .homeCellar)
        #expect(SourceConnectionRouteNamingPolicy.label(for: .publicAddress, custom: nil) == .internet)
    }

    @Test("Tapping cycles to the next route and wraps around")
    func cycling() {
        let routes = [local, remote, extra]
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: .localAddress, in: routes) == .publicAddress)
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: .publicAddress, in: routes) == extra.kind)
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: extra.kind, in: routes) == .localAddress)
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: nil, in: routes) == .localAddress)
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: .vendorRemote, in: routes) == .localAddress)
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: .localAddress, in: [local]) == nil)
        #expect(SourceConnectionRouteNamingPolicy.nextRoute(after: nil, in: []) == nil)
    }

    @Test("Only names that differ from the default are stored")
    func storage() {
        var labels = SourceConnectionRouteLabels()
        labels.setLabel(.homeCellar, sourceID: "nas", kind: .localAddress)
        labels.setLabel(.internet, sourceID: "nas", kind: .publicAddress)
        #expect(labels.label(sourceID: "nas", kind: .localAddress) == .homeCellar)
        #expect(labels.label(sourceID: "nas", kind: .publicAddress) == nil)
        #expect(labels.labels == ["nas": ["localAddress": "homeCellar"]])

        labels.setLabel(.lan, sourceID: "nas", kind: .localAddress)
        #expect(labels.labels.isEmpty)

        labels.setLabel(.dataHog, sourceID: "nas", kind: extra.kind)
        labels.removeSource("nas")
        #expect(labels.labels.isEmpty)
    }

    @Test("Every preset except the two defaults sits in exactly one group")
    func grouping() {
        #expect(SourceConnectionRouteLabel.lan.category == nil)
        #expect(SourceConnectionRouteLabel.internet.category == nil)
        let grouped = SourceConnectionRouteLabel.Category.allCases.flatMap(\.labels)
        #expect(grouped.count == SourceConnectionRouteLabel.allCases.count - 2)
        #expect(Set(grouped).count == grouped.count)
    }

    @Test("Round trips and ignores names it does not know")
    func coding() {
        var labels = SourceConnectionRouteLabels()
        labels.setLabel(.godfathersStash, sourceID: "a", kind: .publicAddress)
        let decoded = SourceConnectionRouteLabels.decode(labels.encoded())
        #expect(decoded == labels)

        let future = Data(#"{"labels":{"a":{"localAddress":"moonBase"}}}"#.utf8)
        #expect(SourceConnectionRouteLabels.decode(future).label(sourceID: "a", kind: .localAddress) == nil)
        #expect(SourceConnectionRouteLabels.decode(Data("not json".utf8)) == SourceConnectionRouteLabels())
        #expect(SourceConnectionRouteLabels.decode(nil) == SourceConnectionRouteLabels())
    }
}
