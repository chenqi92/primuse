import Foundation
import Testing
@testable import PrimuseKit

struct ListeningSharePackageTests {
    @Test func nearbySharingDoesNotAdvertiseToLegacyFileReceivers() throws {
        let old = try JSONDecoder().decode(WiFiTransferIdentity.self, from: Data(#"{"id":"old","name":"Old phone","platform":"iPhone"}"#.utf8))
        #expect(old.supportsListeningShares == nil)
        #expect(old.serviceType == "_primuse-xfer._tcp")
        let current = WiFiTransferIdentity(id: "new", name: "Phone", platform: "iPhone", supportsListeningShares: true)
        #expect(current.serviceType == "_primuse-share._tcp")
        #expect(try JSONDecoder().decode(WiFiTransferIdentity.self, from: JSONEncoder().encode(current)).supportsListeningShares == true)
    }
    private func package() -> ListeningSharePackage {
        var package = ListeningSharePackage(title: "Night Signal")
        var station = RadioStation(name: "Night Signal", streamURL: "https://radio.example.org/live.aac")
        station.folderName = "Evening"; station.tagNames = ["Ambient"]
        station.logoData = Data([1, 2, 3])
        station.sourceID = "private-server"; station.lastPlayedAt = Date()
        package.stations = [.init(station)]
        return package
    }

    @Test(.timeLimit(.minutes(1))) func approvedNearbyTransferPreservesPackage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("received")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = package()
        let file = directory.appendingPathComponent("test.primuseshare")
        try ListeningShareArchive.write(original, to: file)
        let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        let (events, continuation) = AsyncStream.makeStream(of: WiFiTransferServer.Event.self)
        let server = WiFiTransferServer(root: root, page: "", testingHost: "127.0.0.1") { continuation.yield($0) }
        server.start()
        defer { server.stop(); continuation.finish() }
        var iterator = events.makeAsyncIterator()
        guard case .ready(let address) = await iterator.next() else { Issue.record("Listener unavailable"); return }
        let client = try WiFiTransferClient(address: address, code: server.accessCode)
        let invitation = try await client.invite(sender: "Friend", fileCount: 1, byteCount: size)
        guard case .invitation = await iterator.next() else { Issue.record("Invitation missing"); return }
        await #expect(throws: WiFiTransferError.unauthorized) {
            try await client.upload(file: file, path: "friend.primuseshare", size: size, ticket: invitation.id) { _ in }
        }
        server.answer(invitationID: invitation.id, accepted: true)
        try await client.waitForAcceptance(invitation.id)
        try await client.upload(file: file, path: "friend.primuseshare", size: size, ticket: invitation.id) { _ in }
        await client.finish(invitation.id)
        #expect(try ListeningShareArchive.read(root.appendingPathComponent("friend.primuseshare")).package == original)
    }

    @Test func archiveRoundTripPreservesPortableFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = package()
        let file = directory.appendingPathComponent("test.primuseshare")
        try ListeningShareArchive.write(original, to: file)
        let decoded = try ListeningShareArchive.read(file)
        #expect(decoded.package == original)
        let station = decoded.package.stations[0].makeStation()
        #expect(station.assignedFolderName == "Evening")
        #expect(station.assignedTagNames == ["Ambient"])
        #expect(station.logoData == Data([1, 2, 3]))
        #expect(station.sourceID == nil && station.lastPlayedAt == nil)
    }

    @Test func binaryAssetsRoundTripAndTruncationIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(repeating: 42, count: 1024 * 1024 + 17)
        let asset = ListeningSharePackage.Asset(size: Int64(bytes.count))
        let audio = directory.appendingPathComponent("chapter.mp3")
        try bytes.write(to: audio)
        var package = package()
        package.assets = [asset]
        package.books = [.init(title: "The Lantern Keeper", tracks: [.init(title: "One", fileName: "one.mp3", assetID: asset.id)])]
        let archive = directory.appendingPathComponent("book.primuseshare")
        try ListeningShareArchive.write(package, assets: [asset.id: audio], to: archive)
        let contents = try ListeningShareArchive.read(archive)
        let output = directory.appendingPathComponent("restored.mp3")
        try contents.extract(assetID: asset.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: 100)
        try handle.close()
        #expect(throws: (any Error).self) { try ListeningShareArchive.read(archive) }
    }

    @Test(arguments: ["https://user:password@example.org/live", "https://example.org/live?access_token=secret",
                      "https://example.org/live?X-Amz-Signature=secret", "https://example.org/rest/stream?u=listener&p=secret",
                      "https://example.org/rest/stream?u=listener&t=hash&s=salt", "file:///private/test.mp3", "javascript:alert(1)"])
    func credentialAndNonNetworkURLsAreRejected(_ url: String) {
        #expect(throws: ListeningShareError.unsafeURL) { try ListeningShareURLPolicy.validate(url) }
    }

    @Test func publicArtworkSizingParametersRemainShareable() throws {
        let url = "https://media.npr.org/assets/podcast.jpg?s=1400&c=85&f=jpeg"
        #expect(try ListeningShareURLPolicy.validate(url, publicSharing: true).absoluteString == url)
    }

    @Test func localURLsOnlyTravelLocally() throws {
        #expect(try ListeningShareURLPolicy.validate("http://192.168.1.3/radio").host == "192.168.1.3")
        #expect(throws: ListeningShareError.privateURL) {
            try ListeningShareURLPolicy.validate("http://192.168.1.3/radio", publicSharing: true)
        }
    }

    @Test func unknownSettingsAndAssetPathsCannotBeImported() throws {
        var package = package()
        package.settings["apiKey"] = try ListeningShareSettingsPolicy.encode("secret")
        #expect(throws: ListeningShareError.invalidSettings) { try package.validated() }
        package.settings = [:]
        package.assets = [.init(id: "../../outside", size: 2)]
        #expect(throws: ListeningShareError.invalidPackage) { try package.validated() }
        #expect(!ListeningShareArchive.validAudioFileName("../chapter.mp3"))
        #expect(!ListeningShareArchive.validAudioFileName(".hidden.mp3"))
    }

    @Test func unknownVersionsDuplicatesAndUnreferencedAssetsAreRejected() throws {
        var package = package()
        package.version = 2
        #expect(throws: ListeningShareError.unsupportedVersion) { try package.validated() }
        package.version = 1
        package.stations += package.stations
        #expect(throws: ListeningShareError.invalidPackage) { try package.validated() }
        package.stations.removeLast()
        package.assets = [.init(size: 1024)]
        #expect(throws: ListeningShareError.invalidPackage) { try package.validated() }
    }

    @Test func presetsRoundTripAndRejectUnboundedCurves() throws {
        let valid = try ListeningShareSettingsPolicy.encode(Array(repeating: 3.0, count: PrimuseConstants.eqBandCount))
        try ListeningShareSettingsPolicy.validate(valid, key: "eq.customBands")
        #expect((try ListeningShareSettingsPolicy.decode(valid) as? [Double])?.first == 3)
        let invalid = try ListeningShareSettingsPolicy.encode([1000.0])
        #expect(throws: ListeningShareError.invalidSettings) { try ListeningShareSettingsPolicy.validate(invalid, key: "eq.customBands") }
    }
}

struct ListeningShareCodeTests {
    private func package() throws -> ListeningSharePackage {
        var package = ListeningSharePackage(title: "夜航 Radio")
        var station = RadioStation(name: "夜航", streamURL: "https://radio.example.org/live.aac")
        station.folderName = "夜晚"; station.tagNames = ["Ambient", "中文"]
        station.logoData = Data([137, 80, 78, 71, 13, 10, 26, 10])
        package.stations = [.init(station)]
        let show = PodcastShow(id: "night-notes", feedURL: URL(string: "https://podcasts.example.org/feed.xml")!,
                               title: "Night Notes", artworkURL: URL(string: "https://podcasts.example.org/cover.jpg"),
                               subscribedAt: Date(timeIntervalSince1970: 1_800_000_000), folderName: "Evening", tagNames: ["Stories"])
        package.podcasts = [.init(show)]
        package.settings["eq.enabled"] = try ListeningShareSettingsPolicy.encode(true)
        package.backgrounds = [Data([1, 2, 3])]
        package.books = [.init(title: "The Lantern Keeper", tracks: [.init(title: "One", fileName: "chapter.mp3", publicURL: "https://audio.example.org/chapter.mp3")])]
        return package
    }

    @Test func offlineCodeAndJSONPreserveAllExportedFields() throws {
        let original = try package()
        let code = try ListeningShareCode.encode(original)
        #expect(code.hasPrefix("PM1."))
        #expect(try ListeningShareCode.decode(code) == original)
        #expect(try ListeningShareJSON.decode(ListeningShareJSON.encode(original)) == original)
        let wrapped = code.enumerated().map { $0.offset % 40 == 0 ? "\n" + String($0.element) : String($0.element) }.joined()
        #expect(try ListeningShareCode.decode(" \t" + wrapped + "\n") == original)
    }

    @Test func corruptTruncatedAndUnsupportedCodesAreRejected() throws {
        let code = try ListeningShareCode.encode(package())
        #expect(throws: Error.self) { try ListeningShareCode.decode(String(code.dropLast(8))) }
        #expect(throws: Error.self) { try ListeningShareCode.decode(code + "AAAA") }
        #expect(throws: ListeningShareCodeError.unsupportedVersion) { try ListeningShareCode.decode(code.replacingOccurrences(of: "PM1.", with: "PM2.")) }
        var bytes = Array(code.utf8); bytes[12] = bytes[12] == 65 ? 66 : 65
        #expect(throws: Error.self) { try ListeningShareCode.decode(String(decoding: bytes, as: UTF8.self)) }
        #expect(throws: ListeningShareCodeError.tooLarge) { try ListeningShareCode.decode(String(repeating: "A", count: ListeningShareCode.maximumCharacters * 2 + 1)) }
    }

    @Test func decompressionCannotExceedDeclaredSize() throws {
        let code = try ListeningShareCode.encode(package())
        var text = String(code.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        var payload = try #require(Data(base64Encoded: text))
        payload.replaceSubrange(0..<4, with: [0, 0, 0, 1])
        let forged = "PM1." + payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(throws: ListeningShareCodeError.tooLarge) { try ListeningShareCode.decode(forged) }
    }

    @Test func binaryAudioRequiresAFileInsteadOfAnIncompleteCode() throws {
        var package = try package()
        let asset = ListeningSharePackage.Asset(size: 1)
        package.assets = [asset]
        package.books[0].tracks = [.init(title: "One", fileName: "one.mp3", assetID: asset.id)]
        #expect(throws: ListeningShareCodeError.requiresFile) { try ListeningShareCode.encode(package) }
        #expect(throws: ListeningShareCodeError.requiresFile) { try ListeningShareJSON.encode(package) }
    }

    @Test func unsafeCredentialsAndUnknownSettingsRemainRejected() throws {
        var package = try package()
        package.stations[0].streamURL = "https://user:password@radio.example.org/live.aac"
        #expect(throws: Error.self) { try ListeningShareCode.encode(package) }
        package.stations[0].streamURL = "https://radio.example.org/live.aac"
        package.settings["source.password"] = Data()
        #expect(throws: Error.self) { try ListeningShareJSON.encode(package) }
    }

    @Test func largeImagesRemainInJSONWhenCodeIsTooLong() throws {
        var package = try package()
        var generator = SystemRandomNumberGenerator()
        package.stations[0].logo = Data((0..<80_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        #expect(throws: ListeningShareCodeError.tooLarge) { try ListeningShareCode.encode(package) }
        #expect(try ListeningShareJSON.decode(ListeningShareJSON.encode(package)) == package)
    }

    @Test func networkCodesPreserveTheKeyAndServer() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        for host in ["share.soundisle.com", "relay.example.org:8443"] {
            for identifier in ["123456", "abcdefghijklmnopqrstuvwx"] {
                let url = try #require(URL(string: "https://\(host)/s/\(identifier)#k=\(key)"))
                let code = try ListeningShareCode.networkCode(for: url)
                #expect(try ListeningShareCode.networkReference(code).shareURL == url)
                #expect(try ListeningShareCode.networkReference(url.absoluteString).keyToken == key)
                if host == "share.soundisle.com", identifier == "123456" { #expect(code.count == 55) }
            }
        }
    }

    @Test(arguments: ["http://share.soundisle.com", "https://127.0.0.1", "https://10.0.0.1", "https://user:pass@relay.example.org"])
    func networkCodesRejectUnsafeServers(_ origin: String) throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: origin + "/s/123456#k=" + key))
        #expect(throws: Error.self) { try ListeningShareCode.networkCode(for: url) }
        #expect(throws: Error.self) { try ListeningShareCode.networkReference("PMN1.123456") }
    }

    @Test func cameraImportLinksPreserveTheServerIdentifierAndKey() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        for origin in ["https://share.soundisle.com", "https://relay.example.org:8443"] {
            let share = try #require(URL(string: origin + "/s/123456#k=" + key))
            let link = try ListeningShareCode.appImportURL(for: share)
            #expect(link.scheme == "primuse")
            #expect(link.host == "import-code")
            #expect(try ListeningShareCode.networkReference(appImportURL: link).shareURL == share)
        }
    }

    @Test func cameraImportLinksRejectExtraFieldsAndUnsafeTargets() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let code = "PMN1.123456." + key
        for raw in [
            "https://import-code?code=" + code,
            "primuse://other?code=" + code,
            "primuse://user@import-code?code=" + code,
            "primuse://import-code:443?code=" + code,
            "primuse://import-code/path?code=" + code,
            "primuse://import-code?code=" + code + "#extra",
            "primuse://import-code?code=" + code + "&code=" + code,
            "primuse://import-code?code=" + code + "&extra=1",
            "primuse://import-code?code=PMN1.123456",
            "primuse://import-code?code=https://127.0.0.1/s/123456",
            "primuse://import-code?code=PMN1.aHR0cHM6Ly8xMjcuMC4wLjE.123456." + key,
            "primuse://import-code?code=primuse://import-code"
        ] {
            #expect(throws: Error.self) {
                try ListeningShareCode.networkReference(appImportURL: #require(URL(string: raw)))
            }
        }
    }
}

struct ListeningShareCodeResolverTests {
    @Test func publicTicketKeepsDecryptionKeyOnTheClient() async throws {
        let fixture = try ShareCodeHTTPFixture { request, _ in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/s/123456/import")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://" + request.url!.host!)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return .ticket(request)
        }
        defer { fixture.close() }
        let result = try await ListeningShareCodeResolver.resolve(fixture.reference, password: "", session: fixture.session)
        #expect(result.fragment == "k=" + fixture.reference.keyToken)
        #expect(result.path == "/i/abcdefghijklmnopqrstuvwx")
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests.allSatisfy { !($0.url?.absoluteString.contains(fixture.reference.keyToken) ?? true) })
    }

    @Test func passwordUnlockUsesEscapedBodyAndScopedCookie() async throws {
        let fixture = try ShareCodeHTTPFixture { request, index in
            switch index {
            case 0: return .init(status: 401)
            case 1:
                #expect(request.url?.path == "/s/123456/auth")
                #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == "password=a%2Bb%26c%3D%E4%B8%AD")
                return .init(status: 200, headers: ["Set-Cookie": "primuse_share_session=fixture; Path=/s/123456; Max-Age=1800; Secure; HttpOnly; SameSite=Strict"])
            default:
                #expect(index == 2)
                #expect(request.url?.path == "/s/123456/import")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "primuse_share_session=fixture")
                return .ticket(request)
            }
        }
        defer { fixture.close() }
        _ = try await ListeningShareCodeResolver.resolve(fixture.reference, password: "a+b&c=中", session: fixture.session)
        #expect(fixture.requests.count == 3)
        #expect(fixture.requests.allSatisfy { $0.url?.query == nil && $0.url?.fragment == nil })
    }

    @Test(arguments: [401, 404, 410, 429, 500])
    func errorsDoNotBecomeImportLinks(_ status: Int) async throws {
        let fixture = try ShareCodeHTTPFixture { _, _ in .init(status: status) }
        defer { fixture.close() }
        let expected: ListeningShareCodeResolver.Failure = switch status {
        case 401: .passwordRequired
        case 404, 410: .unavailable
        case 429: .rateLimited
        default: .invalidResponse
        }
        await #expect(throws: expected) {
            try await ListeningShareCodeResolver.resolve(fixture.reference, password: "", session: fixture.session)
        }
    }

    @Test(arguments: ["https://other.example.org/i/abcdefghijklmnopqrstuvwx", "http://relay.example.org/i/abcdefghijklmnopqrstuvwx", "/i/abcdefghijklmnopqrstuvwx"])
    func untrustedTicketsAreRejected(_ target: String) async throws {
        let fixture = try ShareCodeHTTPFixture { _, _ in
            .init(status: 201, data: try! JSONEncoder().encode(["importURL": target]))
        }
        defer { fixture.close() }
        await #expect(throws: ListeningShareCodeResolver.Failure.invalidResponse) {
            try await ListeningShareCodeResolver.resolve(fixture.reference, password: "", session: fixture.session)
        }
    }

    @Test(arguments: ["session=fixture; Path=/; Secure", "session=fixture; Path=/s/123456", "session=fixture; Domain=other.example.org; Path=/s/123456; Secure"])
    func unscopedOrInsecureCookiesAreRejected(_ cookie: String) async throws {
        let fixture = try ShareCodeHTTPFixture { _, index in
            index == 0 ? .init(status: 401) : .init(status: 200, headers: ["Set-Cookie": cookie])
        }
        defer { fixture.close() }
        await #expect(throws: ListeningShareCodeResolver.Failure.invalidResponse) {
            try await ListeningShareCodeResolver.resolve(fixture.reference, password: "fixture", session: fixture.session)
        }
        #expect(fixture.requests.count == 2)
    }

    @Test func oversizedResponseIsRejectedBeforeJSONDecoding() async throws {
        let fixture = try ShareCodeHTTPFixture { _, _ in .init(status: 201, data: Data(repeating: 32, count: 65_537)) }
        defer { fixture.close() }
        await #expect(throws: ListeningShareCodeResolver.Failure.invalidResponse) {
            try await ListeningShareCodeResolver.resolve(fixture.reference, password: "", session: fixture.session)
        }
    }
}

private final class ShareCodeHTTPFixture: @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var data = Data()
        static func ticket(_ request: URLRequest) -> Self {
            .init(status: 201, data: try! JSONEncoder().encode(["importURL": "https://" + request.url!.host! + "/i/abcdefghijklmnopqrstuvwx"]))
        }
    }
    let reference: ListeningShareCode.NetworkReference
    let session: URLSession
    let handler: @Sendable (URLRequest, Int) -> Reply
    private let lock = NSLock()
    private var log: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { log } }

    init(handler: @escaping @Sendable (URLRequest, Int) -> Reply) throws {
        self.handler = handler
        let host = UUID().uuidString.lowercased() + ".example.org"
        let key = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        reference = try ListeningShareCode.networkReference("https://\(host)/s/123456#k=\(key)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ShareCodeURLProtocol.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        ShareCodeURLProtocol.register(self, host: host)
    }
    func close() {
        session.invalidateAndCancel()
        ShareCodeURLProtocol.unregister(host: reference.origin.host!)
    }
    func respond(_ request: URLRequest) -> Reply {
        let index = lock.withLock { let index = log.count; log.append(request); return index }
        return handler(request, index)
    }
}

private final class ShareCodeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: ShareCodeHTTPFixture] = [:]
    static func register(_ fixture: ShareCodeHTTPFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    static func unregister(host: String) { _ = lock.withLock { fixtures.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        var captured = request
        if let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data(), bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            captured.httpBody = body
        }
        let reply = fixture.respond(captured)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
