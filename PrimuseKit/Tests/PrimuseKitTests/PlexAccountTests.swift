import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PrimuseKit

/// plex.tv 账号登录：服务器清单解析、线路挑选、`*.plex.direct` 识别与已绑定服务器的刷新规则。
struct PlexAccountTests {
    private static let ownHash = "0123456789abcdef0123456789abcdef"
    private static let friendHash = "fedcba9876543210fedcba9876543210"

    /// 按 plex.tv `/api/v2/resources` 的真实形状写的样本：自己的服务器（Docker 网桥地址 + 家用网段 +
    /// 公网直连 + 中转）、一台不是服务器的手机、Plex Home 共享的服务器、好友分享的服务器，外加一项坏数据。
    private static let resourcesJSON = """
    [
      {"name":"Living Room","product":"Plex Media Server","productVersion":"1.41.0.8992","platform":"Linux",
       "clientIdentifier":"own-server","provides":"server","ownerId":null,"sourceTitle":null,
       "publicAddress":"203.0.113.7","accessToken":"own-server-token","owned":true,"home":false,"synced":false,
       "relay":true,"presence":true,"httpsRequired":false,"publicAddressMatches":false,
       "dnsRebindingProtection":false,"natLoopbackSupported":false,
       "connections":[
         {"protocol":"https","address":"172.17.0.2","port":32400,
          "uri":"https://172-17-0-2.\(ownHash).plex.direct:32400","local":true,"relay":false,"IPv6":false},
         {"protocol":"https","address":"192.168.1.10","port":32400,
          "uri":"https://192-168-1-10.\(ownHash).plex.direct:32400","local":true,"relay":false,"IPv6":false},
         {"protocol":"https","address":"203.0.113.7","port":32400,
          "uri":"https://203-0-113-7.\(ownHash).plex.direct:32400","local":false,"relay":false,"IPv6":false},
         {"protocol":"https","address":"198.51.100.20","port":8443,
          "uri":"https://198-51-100-20.\(ownHash).plex.direct:8443","local":false,"relay":true,"IPv6":false},
         "not a connection"
       ]},
      {"name":"iPhone","product":"Plex for iOS","clientIdentifier":"phone","provides":"client,player,pubsub-player",
       "owned":true,"connections":[]},
      {"name":"Zeta Shared","clientIdentifier":"friend-server","provides":"server","sourceTitle":"alice",
       "accessToken":"friend-server-token","owned":false,"home":false,"presence":false,
       "publicAddressMatches":false,"httpsRequired":true,
       "connections":[
         {"protocol":"https","address":"192.168.0.5","port":32400,
          "uri":"https://192-168-0-5.\(friendHash).plex.direct:32400","local":true,"relay":false,"IPv6":false},
         {"protocol":"https","address":"198.51.100.21","port":8443,
          "uri":"https://198-51-100-21.\(friendHash).plex.direct:8443","local":false,"relay":true,"IPv6":false}
       ]},
      {"name":"Attic","clientIdentifier":"home-server","provides":"server","owned":"0","home":"1",
       "accessToken":"home-server-token","presence":1,"connections":[]},
      "garbage"
    ]
    """

    private static func servers() throws -> [PlexResource] {
        try PlexResourceList.decodeServers(from: Data(resourcesJSON.utf8))
    }

    @Test func decodesServersOwnedFirstAndSkipsClientsAndGarbage() throws {
        let servers = try Self.servers()
        #expect(servers.map(\.clientIdentifier) == ["own-server", "home-server", "friend-server"])

        let own = servers[0]
        #expect(own.isOwned)
        #expect(own.accessToken == "own-server-token")
        #expect(own.ownerName == nil)
        #expect(own.connections.count == 4)

        let home = servers[1]
        #expect(home.isOwned == false)
        #expect(home.isHome)
        #expect(home.isOnline)

        let friend = servers[2]
        #expect(friend.ownerName == "alice")
        #expect(friend.isOnline == false)
        #expect(friend.httpsRequired)
    }

    @Test func ownServerPrefersHomeSubnetOverDockerBridgeAndDirectOverRelay() throws {
        let routes = PlexServerConnectionPlanner.routes(for: try Self.servers()[0])
        #expect(routes.local == PlexServerRoute(
            host: "192-168-1-10.\(Self.ownHash).plex.direct",
            port: 32400,
            useSsl: true
        ))
        #expect(routes.remote == PlexServerRoute(
            host: "203-0-113-7.\(Self.ownHash).plex.direct",
            port: 32400,
            useSsl: true
        ))
        #expect(routes.reachesOnlyThroughRelay == false)
    }

    @Test func friendsServerAwayFromItsNetworkSkipsItsLANAddressAndFallsBackToRelay() throws {
        let friend = try Self.servers()[2]
        let routes = PlexServerConnectionPlanner.routes(for: friend)
        #expect(routes.local == nil)
        #expect(routes.remote?.isRelay == true)
        #expect(routes.remote?.port == 8443)
        #expect(routes.reachesOnlyThroughRelay)
    }

    @Test func sharedServerOnTheSameNetworkKeepsItsLANAddress() {
        let resource = PlexResource(
            name: "Family",
            clientIdentifier: "family",
            isOwned: false,
            accessToken: "t",
            publicAddressMatches: true,
            connections: [
                .init(scheme: "https", address: "10.0.0.8", port: 32400,
                      uri: "https://10-0-0-8.\(Self.ownHash).plex.direct:32400", isLocal: true),
            ]
        )
        let routes = PlexServerConnectionPlanner.routes(for: resource)
        #expect(routes.local?.host == "10-0-0-8.\(Self.ownHash).plex.direct")
        #expect(routes.remote == nil)
    }

    @Test func dnsRebindingProtectionFallsBackToPlainLANAddressUnlessHTTPSIsRequired() {
        func resource(httpsRequired: Bool) -> PlexResource {
            PlexResource(
                name: "Box",
                clientIdentifier: "box",
                isOwned: true,
                accessToken: "t",
                httpsRequired: httpsRequired,
                dnsRebindingProtection: true,
                connections: [
                    .init(scheme: "https", address: "192.168.50.2", port: 32400,
                          uri: "https://192-168-50-2.\(Self.ownHash).plex.direct:32400", isLocal: true),
                ]
            )
        }
        #expect(PlexServerConnectionPlanner.routes(for: resource(httpsRequired: false)).local
            == PlexServerRoute(host: "192.168.50.2", port: 32400, useSsl: false))
        #expect(PlexServerConnectionPlanner.routes(for: resource(httpsRequired: true)).local?.useSsl == true)
    }

    @Test func ipv6ConnectionIsOnlyALastResort() {
        let both = PlexResource(
            name: "Dual",
            clientIdentifier: "dual",
            isOwned: true,
            accessToken: "t",
            connections: [
                .init(scheme: "https", address: "2001:db8::7", port: 32400,
                      uri: "https://[2001:db8::7]:32400", isLocal: false, isIPv6: true),
                .init(scheme: "https", address: "203.0.113.9", port: 32400,
                      uri: "https://203-0-113-9.\(Self.ownHash).plex.direct:32400", isLocal: false),
            ]
        )
        #expect(PlexServerConnectionPlanner.routes(for: both).remote?.host
            == "203-0-113-9.\(Self.ownHash).plex.direct")

        let onlyIPv6 = PlexResource(
            name: "V6",
            clientIdentifier: "v6",
            isOwned: true,
            accessToken: "t",
            connections: [
                .init(scheme: "http", address: "2001:db8::7", port: 32400,
                      uri: "http://[2001:db8::7]:32400", isLocal: false, isIPv6: true),
            ]
        )
        let route = PlexServerConnectionPlanner.routes(for: onlyIPv6).remote
        #expect(route?.host == "2001:db8::7")
        #expect(route?.useSsl == false)
    }

    @Test func serverWithoutUsableConnectionsCannotBeSelected() throws {
        let home = try Self.servers()[1]
        #expect(PlexServerConnectionPlanner.routes(for: home).isEmpty)
        #expect(PlexServerSelection(resource: home, accountToken: "account") == nil)

        let own = try #require(PlexServerSelection(resource: try Self.servers()[0], accountToken: "account"))
        #expect(own.serverToken == "own-server-token")
    }

    @Test func serverTokenFallsBackToAccountTokenForOwnServer() throws {
        let resource = PlexResource(
            name: "Old",
            clientIdentifier: "old",
            isOwned: true,
            accessToken: nil,
            connections: [
                .init(scheme: "http", address: "192.168.1.3", port: 32400,
                      uri: "http://192.168.1.3:32400", isLocal: true),
            ]
        )
        let selection = try #require(PlexServerSelection(resource: resource, accountToken: "account"))
        #expect(selection.serverToken == "account")
    }

    @Test func plexDirectHostRevealsItsEmbeddedAddress() {
        #expect(PlexDirectHost.embeddedIPv4Address("192-168-1-10.\(Self.ownHash).plex.direct") == "192.168.1.10")
        #expect(PlexDirectHost.embeddedIPv4Address("203-0-113-7.\(Self.ownHash.uppercased()).PLEX.DIRECT") == "203.0.113.7")
        #expect(PlexDirectHost.embeddedIPv4Address("192-168-1-10.short.plex.direct") == nil)
        #expect(PlexDirectHost.embeddedIPv4Address("300-1-1-1.\(Self.ownHash).plex.direct") == nil)
        #expect(PlexDirectHost.embeddedIPv4Address("192-168-1.\(Self.ownHash).plex.direct") == nil)
        #expect(PlexDirectHost.embeddedIPv4Address("music.example.com") == nil)
    }

    @Test func refreshReplacesPlexProvidedAddressesAndKeepsCustomOnes() {
        let current = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(
                host: "192-168-1-10.\(Self.ownHash).plex.direct", port: 32400, useSsl: true
            ),
            publicEndpoint: SourceConnectionEndpoint(host: "plex.example.com", port: 443, useSsl: true)
        )
        let routes = PlexServerRoutes(
            local: PlexServerRoute(host: "192-168-1-22.\(Self.ownHash).plex.direct", port: 32400, useSsl: true),
            remote: PlexServerRoute(host: "203-0-113-8.\(Self.ownHash).plex.direct", port: 32400, useSsl: true)
        )
        let refreshed = PlexServerLinkRefreshPolicy.refreshedConfiguration(current: current, routes: routes)
        #expect(refreshed?.localEndpoint?.host == "192-168-1-22.\(Self.ownHash).plex.direct")
        // 用户自己的反代域名不动。
        #expect(refreshed?.publicEndpoint?.host == "plex.example.com")
    }

    @Test func refreshFillsEmptySlotsKeepsMissingOnesAndReportsNoChange() {
        let current = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "192.168.1.10", port: 32400, useSsl: false)
        )
        let onlyRemote = PlexServerRoutes(
            local: nil,
            remote: PlexServerRoute(host: "203-0-113-8.\(Self.ownHash).plex.direct", port: 32400, useSsl: true)
        )
        let refreshed = PlexServerLinkRefreshPolicy.refreshedConfiguration(current: current, routes: onlyRemote)
        #expect(refreshed?.localEndpoint?.host == "192.168.1.10")
        #expect(refreshed?.publicEndpoint?.host == "203-0-113-8.\(Self.ownHash).plex.direct")

        #expect(PlexServerLinkRefreshPolicy.refreshedConfiguration(current: refreshed, routes: onlyRemote) == nil)
        #expect(PlexServerLinkRefreshPolicy.refreshedConfiguration(
            current: current,
            routes: PlexServerRoutes(local: nil, remote: nil)
        ) == nil)
    }

    @Test func refreshedTokenOnlyWhenTheServerHandsOutADifferentOne() throws {
        let friend = try Self.servers()[2]
        #expect(PlexServerLinkRefreshPolicy.refreshedToken(current: "friend-server-token", resource: friend) == nil)
        #expect(PlexServerLinkRefreshPolicy.refreshedToken(current: "revoked", resource: friend) == "friend-server-token")
        #expect(PlexServerLinkRefreshPolicy.refreshedToken(current: nil, resource: friend) == "friend-server-token")
    }

    @Test func pinDecodesPendingAndAuthorizedStates() throws {
        // 2026-10-01 从 plex.tv 实际拿到的响应形状（位置信息换成了占位值）：网页授权用的长码 30 分钟、
        // plex.tv/link 的 4 位码 15 分钟。
        let web = try JSONDecoder().decode(PlexPin.self, from: Data("""
        {"id":1899765704,"code":"l91xft5ypr1n7588alsymxoy8","product":"Primuse","trusted":false,
         "qr":"https://plex.tv/api/v2/pins/qr/l91xft5ypr1n7588alsymxoy8","clientIdentifier":"primuse-probe",
         "location":{"code":"XX","european_union_member":false,"continent_code":"XX","country":"Nowhere",
                     "city":"Nowhere","time_zone":"Etc/UTC","postal_code":"00000",
                     "in_privacy_restricted_country":false,"in_privacy_restricted_region":false,
                     "subdivisions":"Nowhere","coordinates":"0, 0"},
         "expiresIn":1800,"createdAt":"2026-10-01T22:39:52Z","expiresAt":"2026-10-01T23:09:52Z",
         "authToken":null,"newRegistration":null}
        """.utf8))
        #expect(web == PlexPin(id: 1_899_765_704, code: "l91xft5ypr1n7588alsymxoy8", authToken: nil))

        let link = try JSONDecoder().decode(PlexPin.self, from: Data("""
        {"id":1438747364,"code":"9WKP","product":"Primuse","trusted":false,"qr":"https://plex.tv/api/v2/pins/qr/9WKP",
         "clientIdentifier":"primuse-probe","expiresIn":900,"createdAt":"2026-10-01T22:39:52Z",
         "expiresAt":"2026-10-01T22:54:52Z","authToken":null,"newRegistration":null}
        """.utf8))
        #expect(link.code == "9WKP")
        #expect(link.authToken == nil)

        let authorized = try JSONDecoder().decode(PlexPin.self, from: Data("""
        {"id":"5123","code":"ab12cd","authToken":"account-token"}
        """.utf8))
        #expect(authorized.authToken == "account-token")
    }

    #if DEBUG
    @Test func debugFixtureCoversOwnedHomeRelayAndUnreachableServers() {
        let servers = PlexResourceList.debugFixtureServers
        #expect(servers.map(\.clientIdentifier) == ["debug-own", "debug-empty", "debug-home", "debug-friend"])
        let selectable = servers.filter { PlexServerSelection(resource: $0, accountToken: "a") != nil }
        #expect(selectable.map(\.clientIdentifier) == ["debug-own", "debug-home", "debug-friend"])
        #expect(PlexServerConnectionPlanner.routes(for: servers[3]).reachesOnlyThroughRelay)
    }
    #endif

    /// 授权页对 `forwardUrl` 只放行 http(s) 和它自己的白名单 scheme，带上 `primuse://` 会被直接
    /// 跳去 www.plex.tv（#168）。所以地址里只有 clientID、code 和产品名。
    @Test func authorizationPageCarriesClientCodeAndProductOnlyInTheFragment() throws {
        let url = PlexAccountAPI.authorizationPageURL(clientIdentifier: "primuse-abc", code: "ab12cd")
        #expect(url.host == "app.plex.tv")
        #expect(url.path == "/auth")
        #expect(url.query == nil)
        let fragment = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
        )
        #expect(fragment == "?clientID=primuse-abc&code=ab12cd&context%5Bdevice%5D%5Bproduct%5D=Primuse")
        #expect(!fragment.contains("forwardUrl"))
    }

    @Test func clientSendsDeviceHeadersAndMapsStatusCodes() async throws {
        let recorder = RequestRecorder()
        let client = PlexAccountClient(
            clientIdentifier: "primuse-abc",
            platform: "iOS",
            deviceName: "iPhone",
            version: "2.0",
            loader: { request in
                await recorder.record(request)
                let status: Int
                switch request.url?.lastPathComponent {
                case "pins": status = 201
                case "404": status = 404
                case "401": status = 401
                default: status = 200
                }
                let body = request.url?.lastPathComponent == "pins"
                    ? #"{"id":1,"code":"zz","authToken":null}"#
                    : "[]"
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        )

        let pin = try await client.createPin(strong: true)
        #expect(pin.code == "zz")
        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == "strong=true")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "primuse-abc")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Primuse")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == nil)

        await #expect(throws: PlexAccountError.pinExpired) { try await client.checkPin(id: 404) }
        await #expect(throws: PlexAccountError.unauthorized) { try await client.checkPin(id: 401) }

        _ = try await client.servers(accountToken: "account-token")
        let serversRequest = try #require(await recorder.requests.last)
        #expect(serversRequest.value(forHTTPHeaderField: "X-Plex-Token") == "account-token")
        #expect(serversRequest.url?.host == "clients.plex.tv")
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}
