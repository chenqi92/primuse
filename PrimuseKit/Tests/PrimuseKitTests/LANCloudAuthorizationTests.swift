import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple TV cloud sign-in through the phone")
struct LANCloudAuthorizationTests {
    private let key = Data((0..<32).map { UInt8($0) })

    private var link: LANCloudAuthorizationLink {
        LANCloudAuthorizationLink(
            endpoint: LANPairLink(host: "192.168.1.50", port: 54321, key: key, pairCode: "123456",
                                  protocolVersion: LANPairLink.currentProtocolVersion),
            provider: .googleDrive
        )
    }

    @Test func qrContentRoundTripsThroughURL() throws {
        let content = link.qrContent
        #expect(content.hasPrefix("primuse://tv-cloud-auth?"))
        #expect(content.contains("provider=googleDrive"))
        #expect(!content.contains("v="))
        let parsed = try #require(LANCloudAuthorizationLink(url: URL(string: content)!))
        #expect(parsed.provider == .googleDrive)
        #expect(parsed.endpoint.host == "192.168.1.50")
        #expect(parsed.endpoint.port == 54321)
        #expect(parsed.endpoint.key == key)
        #expect(parsed.endpoint.pairCode == "123456")
        #expect(parsed.requestURL == URL(string: "http://192.168.1.50:54321/cloud-auth"))
    }

    @Test func rejectsLinksThatAreNotCompleteCloudSignIns() {
        let pair = link.endpoint.qrContent
        // 扫码直传的配对码不能被当成代为登录。
        #expect(LANCloudAuthorizationLink(url: URL(string: pair)!) == nil)

        let content = link.qrContent
        let withoutProvider = content.replacingOccurrences(of: "&provider=googleDrive", with: "")
        #expect(LANCloudAuthorizationLink(url: URL(string: withoutProvider)!) == nil)
        let unknownProvider = content.replacingOccurrences(of: "provider=googleDrive", with: "provider=nope")
        #expect(LANCloudAuthorizationLink(url: URL(string: unknownProvider)!) == nil)
        let withoutCode = content.replacingOccurrences(of: "&code=123456", with: "")
        #expect(LANCloudAuthorizationLink(url: URL(string: withoutCode)!) == nil)
    }

    @Test func payloadRoundTripsAndRequiresRefreshToken() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = LANCloudAuthorizationPayload(
            provider: .googleDrive, clientID: "client", accessToken: "access",
            refreshToken: "refresh", expiresAt: expiry, tokenType: "Bearer"
        )
        let decoded = try #require(LANCloudAuthorizationPayload.decode(payload.jsonData()))
        #expect(decoded == payload)
        #expect(decoded.isUsable(for: .googleDrive))
        #expect(!decoded.isUsable(for: .oneDrive))

        var missingRefresh = payload
        missingRefresh.refreshToken = nil
        #expect(!missingRefresh.isUsable(for: .googleDrive))
        missingRefresh.refreshToken = ""
        #expect(!missingRefresh.isUsable(for: .googleDrive))

        var missingClient = payload
        missingClient.clientID = ""
        #expect(!missingClient.isUsable(for: .googleDrive))
    }

    @Test func sealedPayloadOnlyOpensWithTheQRCodeKey() throws {
        let payload = LANCloudAuthorizationPayload(
            provider: .googleDrive, clientID: "client", accessToken: "access",
            refreshToken: "refresh", expiresAt: nil, tokenType: nil
        )
        let box = try #require(LANSyncCrypto.seal(payload.jsonData(), key: key))
        #expect(LANSyncCrypto.open(box, key: LANSyncCrypto.randomKey()) == nil)
        let opened = try #require(LANSyncCrypto.open(box, key: key))
        #expect(LANCloudAuthorizationPayload.decode(opened) == payload)
    }
}
