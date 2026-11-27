import Foundation
import Testing
@testable import PrimuseKit

// MARK: - 厂商标识

@Test func addressInputRecognizesBareQuickConnectID() {
    let result = SourceAddressInputPolicy.interpret("mynas", sourceType: .synology)
    #expect(result == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))
}

@Test func addressInputTreatsDotlessTokenAsHostnameWhenAsked() {
    let result = SourceAddressInputPolicy.interpret(
        "mynas",
        sourceType: .synology,
        treatDotlessTokenAsHostname: true
    )
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.host == "mynas")
    #expect(input.explicitScheme == nil)
    #expect(input.explicitPort == nil)
}

@Test func addressInputRecognizesQuickConnectPortalURL() {
    let path = SourceAddressInputPolicy.interpret("quickconnect.to/mynas", sourceType: .synology)
    #expect(path == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))

    // 带路径的形态不受「按主机名解释」开关影响 —— 它已经写明了是厂商入口。
    let forced = SourceAddressInputPolicy.interpret(
        "quickconnect.to/mynas",
        sourceType: .synology,
        treatDotlessTokenAsHostname: true
    )
    #expect(forced == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))
}

@Test func addressInputRecognizesQuickConnectSubdomainWithoutScheme() {
    let bare = SourceAddressInputPolicy.interpret("mynas.quickconnect.to", sourceType: .synology)
    #expect(bare == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))

    let withScheme = SourceAddressInputPolicy.interpret(
        "https://mynas.quickconnect.cn",
        sourceType: .synology
    )
    #expect(withScheme == .vendorIdentifier(kind: .synologyQuickConnect, id: "mynas"))
}

@Test func addressInputRecognizesFNConnectForms() {
    let bare = SourceAddressInputPolicy.interpret("myfnbox", sourceType: .fnMusic)
    #expect(bare == .vendorIdentifier(kind: .fnConnect, id: "myfnbox"))

    let domain = SourceAddressInputPolicy.interpret("myfnbox.5ddd.com", sourceType: .fnMusic)
    #expect(domain == .vendorIdentifier(kind: .fnConnect, id: "myfnbox"))
}

@Test func addressInputKeepsVendorParsingOffTypesWithoutVendorAccess() {
    let result = SourceAddressInputPolicy.interpret("mynas", sourceType: .emby)
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.host == "mynas")
}

@Test func addressInputKeepsShortTokenAsHostnameForFNMusic() {
    // FN ID 至少六位,五个字母的词只可能是主机名。
    let result = SourceAddressInputPolicy.interpret("mynas", sourceType: .fnMusic)
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.host == "mynas")
}

// MARK: - 地址拆解

@Test func addressInputSplitsSchemeHostPortAndPath() {
    let result = SourceAddressInputPolicy.interpret(
        "  https://emby.example.com:8443/media  ",
        sourceType: .emby
    )
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.explicitScheme == "https")
    #expect(input.host == "emby.example.com")
    #expect(input.explicitPort == 8443)
    #expect(input.pathPrefix == "/media")
    #expect(input.hostClass == .public)
    #expect(input.isIPLiteral == false)
    #expect(input.explicitUseSsl == true)
}

@Test func addressInputLeavesUnwrittenSchemeAndPortNil() {
    let result = SourceAddressInputPolicy.interpret("emby.example.com", sourceType: .emby)
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.explicitScheme == nil)
    #expect(input.explicitPort == nil)
    #expect(input.explicitUseSsl == nil)
}

@Test func addressInputAcceptsIPv6InBothBracketedAndBareForms() {
    let bracketed = SourceAddressInputPolicy.interpret("[fd7a:115c:a1e0::1]:8096", sourceType: .emby)
    guard case let .endpoint(bracketedInput) = bracketed else {
        Issue.record("expected an endpoint, got \(bracketed)")
        return
    }
    #expect(bracketedInput.host == "fd7a:115c:a1e0::1")
    #expect(bracketedInput.explicitPort == 8096)
    #expect(bracketedInput.isIPLiteral)
    #expect(bracketedInput.hostClass == .overlay)

    let bare = SourceAddressInputPolicy.interpret("fd00::1", sourceType: .emby)
    guard case let .endpoint(input) = bare else {
        Issue.record("expected an endpoint, got \(bare)")
        return
    }
    #expect(input.host == "fd00::1")
    #expect(input.explicitPort == nil)
    #expect(input.hostClass == .lan)
}

@Test func addressInputKeepsIPv6ZoneIdentifier() {
    let result = SourceAddressInputPolicy.interpret("[fe80::1%en0]:5001", sourceType: .synology)
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.host == "fe80::1%en0")
    #expect(input.explicitPort == 5001)
    #expect(input.isIPLiteral)
}

@Test func addressInputRepairsFullWidthPunctuation() {
    let result = SourceAddressInputPolicy.interpret("192．168．1．10：8096", sourceType: .emby)
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.host == "192.168.1.10")
    #expect(input.explicitPort == 8096)
    #expect(input.hostClass == .lan)
}

@Test func addressInputKeepsReverseProxyPrefixVerbatim() {
    let result = SourceAddressInputPolicy.interpret(
        "https://proxy.example.com/https://nav.example.com:4533",
        sourceType: .navidrome
    )
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.host == "proxy.example.com")
    #expect(input.explicitPort == nil)
    #expect(input.pathPrefix == "/https://nav.example.com:4533")
}

@Test func addressInputClassifiesHostsByNetworkPosition() {
    #expect(SourceAddressInputPolicy.hostClass(of: "localhost") == .loopback)
    #expect(SourceAddressInputPolicy.hostClass(of: "127.0.0.1") == .loopback)
    #expect(SourceAddressInputPolicy.hostClass(of: "::1") == .loopback)
    #expect(SourceAddressInputPolicy.hostClass(of: "192.168.1.10") == .lan)
    #expect(SourceAddressInputPolicy.hostClass(of: "nas.local") == .lan)
    #expect(SourceAddressInputPolicy.hostClass(of: "100.64.0.7") == .overlay)
    #expect(SourceAddressInputPolicy.hostClass(of: "nas.tailnet.ts.net") == .overlay)
    #expect(SourceAddressInputPolicy.hostClass(of: "emby.example.com") == .public)
}

@Test func addressInputStripsMatchingSchemeOnNonHTTPTypes() {
    let result = SourceAddressInputPolicy.interpret("smb://nas.local/music", sourceType: .smb)
    guard case let .endpoint(input) = result else {
        Issue.record("expected an endpoint, got \(result)")
        return
    }
    #expect(input.explicitScheme == "smb")
    #expect(input.host == "nas.local")
    #expect(input.pathPrefix == "/music")
}

@Test func addressInputRejectsSchemeThatDoesNotMatchTheType() {
    #expect(
        SourceAddressInputPolicy.interpret("https://nas.local/music", sourceType: .smb)
            == .invalid(.schemeMismatch)
    )
    #expect(
        SourceAddressInputPolicy.interpret("smb://nas.local", sourceType: .emby)
            == .invalid(.schemeMismatch)
    )
}

@Test func addressInputRejectsUnusableEntries() {
    #expect(SourceAddressInputPolicy.interpret("   ", sourceType: .emby) == .empty)
    #expect(SourceAddressInputPolicy.interpret("https://", sourceType: .emby) == .invalid(.missingHost))
    #expect(SourceAddressInputPolicy.interpret("/only/a/path", sourceType: .emby) == .invalid(.missingHost))
    #expect(SourceAddressInputPolicy.interpret("nas.local:abc", sourceType: .emby) == .invalid(.invalidPort))
    #expect(SourceAddressInputPolicy.interpret("nas.local:99999", sourceType: .emby) == .invalid(.invalidPort))
    #expect(SourceAddressInputPolicy.interpret("nas.local:0", sourceType: .emby) == .invalid(.invalidPort))
    #expect(SourceAddressInputPolicy.interpret("na s.local", sourceType: .emby) == .invalid(.invalidHost))
    #expect(
        SourceAddressInputPolicy.interpret("admin:secret@nas.local:8096", sourceType: .emby)
            == .invalid(.credentialsInAddress)
    )
}

// MARK: - 回显与往返

@Test func renderedAddressOmitsTheSchemeDefaultPort() {
    let endpoint = SourceConnectionEndpoint(host: "emby.example.com", port: 443, useSsl: true)
    #expect(
        SourceAddressInputPolicy.renderedAddress(for: endpoint, sourceType: .emby)
            == "https://emby.example.com"
    )

    let service = SourceConnectionEndpoint(host: "192.168.1.10", port: 8096, useSsl: false)
    #expect(
        SourceAddressInputPolicy.renderedAddress(for: service, sourceType: .emby)
            == "http://192.168.1.10:8096"
    )
}

@Test func renderedAddressBracketsIPv6AndKeepsPathPrefix() {
    let ipv6 = SourceConnectionEndpoint(host: "fd7a:115c:a1e0::1", port: 8920, useSsl: true)
    #expect(
        SourceAddressInputPolicy.renderedAddress(for: ipv6, sourceType: .emby)
            == "https://[fd7a:115c:a1e0::1]:8920"
    )

    let proxied = SourceConnectionEndpoint(
        host: "proxy.example.com",
        port: 443,
        useSsl: true,
        pathPrefix: "/https://nav.example.com:4533"
    )
    #expect(
        SourceAddressInputPolicy.renderedAddress(for: proxied, sourceType: .navidrome)
            == "https://proxy.example.com/https://nav.example.com:4533"
    )
}

@Test func renderedAddressRoundTripsThroughInterpretationAndPlanning() {
    let cases: [(SourceConnectionEndpoint, MusicSourceType)] = [
        (SourceConnectionEndpoint(host: "emby.example.com", port: 443, useSsl: true), .emby),
        (SourceConnectionEndpoint(host: "emby.example.com", port: 8920, useSsl: true), .emby),
        (SourceConnectionEndpoint(host: "192.168.1.10", port: 8096, useSsl: false), .emby),
        (SourceConnectionEndpoint(host: "192.168.1.10", port: 80, useSsl: false), .emby),
        (SourceConnectionEndpoint(host: "fd7a:115c:a1e0::1", port: 8920, useSsl: true), .jellyfin),
        (SourceConnectionEndpoint(host: "fe80::1%en0", port: 5001, useSsl: true), .synology),
        (
            SourceConnectionEndpoint(
                host: "proxy.example.com",
                port: 443,
                useSsl: true,
                pathPrefix: "/https://nav.example.com:4533"
            ),
            .navidrome
        ),
        (
            SourceConnectionEndpoint(host: "nav.example.com", port: 4533, useSsl: false, pathPrefix: "/music"),
            .navidrome
        ),
        (SourceConnectionEndpoint(host: "nas.local", port: 445, useSsl: false), .smb),
        (SourceConnectionEndpoint(host: "nas.local", port: 2222, useSsl: false), .sftp),
        (SourceConnectionEndpoint(host: "dav.example.com", port: 443, useSsl: true, pathPrefix: "/dav"), .webdav)
    ]

    for (endpoint, sourceType) in cases {
        let rendered = SourceAddressInputPolicy.renderedAddress(for: endpoint, sourceType: sourceType)
        let interpretation = SourceAddressInputPolicy.interpret(rendered, sourceType: sourceType)
        guard case let .endpoint(input) = interpretation else {
            Issue.record("\(rendered) did not read back as an endpoint: \(interpretation)")
            continue
        }
        let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: sourceType)
        guard let first = candidates.first else {
            Issue.record("\(rendered) planned no candidate")
            continue
        }
        let rebuilt = SourceConnectionCandidatePlanner.endpoint(for: input, candidate: first)
        #expect(rebuilt == endpoint, "round trip lost information for \(rendered)")
    }
}
