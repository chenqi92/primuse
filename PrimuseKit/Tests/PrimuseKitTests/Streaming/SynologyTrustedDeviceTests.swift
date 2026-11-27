import Foundation
import Testing
@testable import PrimuseKit

@Suite("Synology trusted device playback")
struct SynologyTrustedDeviceTests {
    @Test func otpAuthorizationSurvivesNewResolverAndMusicToAudiobookSwitch() async throws {
        var source = MusicSource(id: "nas", name: "NAS", type: .synology,
                                 host: "nas.example", port: 5001, useSsl: true)
        let credential = SourceCredential(username: "listener", password: "fixture-password")
        let music = Song(id: "music", title: "Music", fileFormat: .mp3,
                         filePath: "/music/song.mp3", sourceID: source.id)
        let book = Song(id: "book", title: "Book", fileFormat: .m4a,
                        filePath: "/books/chapter.m4a", sourceID: source.id)
        let resolver = makeResolver()
        await #expect(throws: StreamResolveError.needs2FA) {
            try await resolver.streamURL(for: music, source: source, credential: credential)
        }
        source.deviceId = try await resolver.loginForDeviceToken(
            source: source, credential: credential, otp: "123456"
        )
        #expect(source.deviceId == "fixture-trusted-device")
        await resolver.invalidateSession(sourceID: source.id)
        let musicURL = try await resolver.streamURL(for: music, source: source, credential: credential)
        #expect(URLComponents(url: musicURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "path" })?.value == music.filePath)

        let restored = try JSONDecoder().decode(MusicSource.self, from: JSONEncoder().encode(source))
        let bookURL = try await makeResolver().streamURL(for: book, source: restored, credential: credential)
        #expect(URLComponents(url: bookURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "path" })?.value == book.filePath)
    }

    private func makeResolver() -> SynologyStreamResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrustedDeviceURLProtocol.self]
        return SynologyStreamResolver(session: URLSession(configuration: configuration))
    }
}

private final class TrustedDeviceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "POST", url.query == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let form = URLComponents(string: "https://fixture.example/?" + String(decoding: body, as: UTF8.self))
        let fields = Dictionary((form?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let named = fields["device_name"] == "Apple TV"
        let otp = named && fields["otp_code"] == "123456" && fields["enable_device_token"] == "yes"
        let trusted = named && fields["device_id"] == "fixture-trusted-device" && fields["otp_code"] == nil
        let payload = otp || trusted
            ? #"{"success":true,"data":{"sid":"fixture-session","did":"fixture-trusted-device"}}"#
            : #"{"success":false,"error":{"code":403}}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
