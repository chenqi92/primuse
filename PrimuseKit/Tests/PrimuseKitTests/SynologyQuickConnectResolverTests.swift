import Foundation
import Testing
@testable import PrimuseKit

@Test func quickConnectIDAcceptsFriendlyInputsAndRejectsDirectHosts() {
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "example-nas") == "example-nas")
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "https://quickconnect.to/example-nas") == "example-nas")
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "quickconnect.cn/Example-NAS") == "Example-NAS")
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "example-nas.cn4.quickconnect.cn") == nil)
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "nas.example.com") == nil)
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "-example-nas") == nil)
    #expect(SynologyQuickConnectResolver.quickConnectID(from: "example-nas-") == nil)
}

@Test func legacySynologySourceKeepsDirectConnectionSemantics() throws {
    let source = MusicSource(
        name: "Legacy NAS",
        type: .synology,
        host: "nas.example.com",
        port: 5001,
        useSsl: true,
        synologyConnectionMode: .quickConnect,
        username: "user"
    )
    let encoded = try JSONEncoder().encode(source)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "synologyConnectionMode")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(MusicSource.self, from: legacyData)
    #expect(decoded.synologyConnectionMode == nil)
    #expect(decoded.effectiveSynologyConnectionMode == .address)
    #expect(decoded.host == "nas.example.com")
    #expect(decoded.port == 5001)
    #expect(decoded.useSsl)
}

@Test func splitDomainAndIPModesMigrateToServerAddress() throws {
    for legacyValue in ["domain", "ip"] {
        let data = Data("\"\(legacyValue)\"".utf8)
        let mode = try JSONDecoder().decode(SynologyConnectionMode.self, from: data)
        #expect(mode == .address)
        #expect(String(decoding: try JSONEncoder().encode(mode), as: UTF8.self) == "\"address\"")
    }
}

@Test func quickConnectModeRoundTripsInSourceSnapshots() throws {
    let source = MusicSource(
        name: "QuickConnect NAS",
        type: .synology,
        host: "example-nas",
        synologyConnectionMode: .quickConnect
    )
    let decoded = try JSONDecoder().decode(MusicSource.self, from: JSONEncoder().encode(source))
    #expect(decoded.synologyConnectionMode == .quickConnect)
    #expect(decoded.effectiveSynologyConnectionMode == .quickConnect)
    #expect(decoded.host == "example-nas")
}

@Test func quickConnectErrorsResolveLocalizedDescriptions() {
    let errors: [SynologyQuickConnectError] = [
        .invalidID,
        .serverNotFound,
        .serviceUnavailable,
        .invalidResponse,
        .unreachable,
    ]
    for error in errors {
        let description = error.errorDescription ?? ""
        #expect(!description.isEmpty)
        #expect(!description.hasPrefix("ext.synology.quickconnect.error."))
    }
}

@Test func quickConnectFollowsControlSiteAndFallsBackToVerifiedRelay() async throws {
    QuickConnectURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuickConnectURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let endpoint = try await SynologyQuickConnectResolver(
        session: session,
        requestTimeout: 1,
        probeTimeout: 1
    ).resolve("example-nas")

    #expect(endpoint.route == .relay)
    #expect(endpoint.baseURL.absoluteString == "https://example-nas.cn4.quickconnect.cn")
    #expect(endpoint.controlHosts == ["global.quickconnect.to", "control.quickconnect.cn"])
}

// All NAS identifiers are fictional and all IPs use RFC 5737 documentation ranges.
private final class QuickConnectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var controlRequestCount = 0

    static func reset() {
        lock.lock()
        controlRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host?.lowercased() else {
            fail(.badURL)
            return
        }

        if host == "global.quickconnect.to" {
            respond(json: #"[{"errno":4,"suberrno":2,"sites":["control.quickconnect.cn"]},{"errno":4,"suberrno":2,"sites":["control.quickconnect.cn"]}]"#)
            return
        }
        if host == "control.quickconnect.cn", url.path == "/Serv.php" {
            Self.lock.lock()
            Self.controlRequestCount += 1
            let isTunnelRequest = Self.controlRequestCount > 1
            Self.lock.unlock()
            if isTunnelRequest {
                respond(json: Self.tunnelResponse)
            } else {
                respond(json: Self.serverInfoResponse)
            }
            return
        }
        if host == "example-nas.cn4.quickconnect.cn" {
            respond(json: #"{"success":true,"ezid":"25f9e794323b453885f5181f1b624d0b"}"#)
            return
        }
        fail(.cannotConnectToHost)
    }

    override func stopLoading() {}

    private func respond(json: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            fail(.badServerResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    private static let serverInfoResponse = #"""
    [
      {
        "errno":0,
        "env":{"control_host":"control.quickconnect.cn","relay_region":"cn"},
        "server":{
          "serverID":"123456789",
          "ddns":"nas.example.com",
          "fqdn":"NULL",
          "external":{"ip":"203.0.113.8"},
          "interface":[],
          "pingpong_path":"/webman/pingpong.cgi?action=cors&quickconnect=true"
        },
        "service":{"port":5001,"ext_port":0,"pingpong":"CONNECTED"},
        "smartdns":{"host":"example-nas.direct.quickconnect.cn","lan":[]}
      },
      {"errno":4,"suberrno":3}
    ]
    """#

    private static let tunnelResponse = #"""
    [
      {
        "errno":0,
        "env":{"control_host":"control.quickconnect.cn","relay_region":"cn4"},
        "server":{
          "serverID":"123456789",
          "pingpong_path":"/webman/pingpong.cgi?action=cors&quickconnect=true"
        },
        "service":{"port":5001,"ext_port":0,"relay_ip":"203.0.113.9","relay_port":30000}
      }
    ]
    """#
}
