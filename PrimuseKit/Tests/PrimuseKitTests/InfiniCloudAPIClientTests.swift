import Foundation
import Testing
@testable import PrimuseKit

@Suite("InfiniCLOUD REST discovery")
struct InfiniCloudAPIClientTests {
    private let apiKey = "0123456789ABCDEF0123456789ABCDEF"

    @Test func requestUsesAppKeyAndUserAppPasswordSeparately() throws {
        let request = try InfiniCloudAPIClient.userRequest(username: "  listener\n", password: " app password ", apiKey: apiKey)
        #expect(request.url?.absoluteString == "https://api.infini-cloud.net/v2/api/ba/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-InfiniCLOUD-API-KEY") == apiKey)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("listener: app password ".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Primuse/") == true)
        #expect(request.url?.query == nil)
    }

    @Test(arguments: ["", "$(INFINICLOUD_API_KEY)", "your_infinicloud_api_key", "not-a-key"])
    func missingBuildConfigurationFailsBeforeSending(value: String) {
        #expect(throws: InfiniCloudAPIClient.Failure.missingAPIKey) {
            try InfiniCloudAPIClient.userRequest(username: "listener", password: "password", apiKey: value)
        }
    }

    @Test(arguments: ["ise.infini-cloud.net", "ise.teracloud.jp"])
    func parsesCurrentAndLegacyNodes(host: String) throws {
        let data = Data("""
        {"result":0,"node":"\(host)","webdav_url":"https://\(host)/dav/",
         "user":"listener","capacity":3286723723264,"api_key":{"vendor":"example"}}
        """.utf8)
        let account = try InfiniCloudAPIClient.account(from: data, statusCode: 200)
        #expect(account.webDAVURL.host == host)
        #expect(account.webDAVURL.path == "/dav")
        #expect(account.username == "listener")
        #expect(account.capacity == 3_286_723_723_264)
    }

    @Test(arguments: [
        "http://ise.infini-cloud.net/dav/", "https://ise.infini-cloud.net.evil.example/dav/",
        "https://evil.example/dav/", "https://user:secret@ise.infini-cloud.net/dav/",
        "https://ise.infini-cloud.net:8443/dav/", "https://ise.infini-cloud.net/dav/?api_key=secret",
        "https://ise.infini-cloud.net/dav/#fragment", "https://ise.infini-cloud.net/v2/dav/"
    ])
    func rejectsEndpointsThatCannotReceiveBasicCredentials(url: String) {
        let data = Data("{\"result\":0,\"webdav_url\":\"\(url)\"}".utf8)
        #expect(throws: InfiniCloudAPIClient.Failure.invalidResponse) {
            try InfiniCloudAPIClient.account(from: data, statusCode: 200)
        }
    }

    @Test(arguments: ["{}", "{\"result\":0}", "{\"result\":1,\"webdav_url\":\"https://ise.infini-cloud.net/dav/\"}", "<html>unavailable</html>"])
    func rejectsMissingOrFailedDiscovery(json: String) {
        #expect(throws: InfiniCloudAPIClient.Failure.invalidResponse) {
            try InfiniCloudAPIClient.account(from: Data(json.utf8), statusCode: 200)
        }
    }

    @Test func distinguishesUserAuthenticationFromAppKeyAndServerErrors() {
        #expect(throws: InfiniCloudAPIClient.Failure.authenticationFailed) {
            try InfiniCloudAPIClient.account(from: Data(), statusCode: 401)
        }
        for code in [302, 403, 429, 503] {
            #expect(throws: InfiniCloudAPIClient.Failure.http(code)) {
                try InfiniCloudAPIClient.account(from: Data(), statusCode: code)
            }
        }
    }

    @Test func unchangedAccountReusesDiscoveredEndpointWhileCredentialEditsRediscover() {
        let source = MusicSource(name: "Music", type: .infiniCloud, host: "ise.infini-cloud.net",
                                 port: 443, username: "listener", basePath: "/dav")
        #expect(!InfiniCloudAPIClient.needsDiscovery(source: source, username: "listener", hasNewPassword: false))
        #expect(InfiniCloudAPIClient.needsDiscovery(source: source, username: "other", hasNewPassword: false))
        #expect(InfiniCloudAPIClient.needsDiscovery(source: source, username: "listener", hasNewPassword: true))
        #expect(InfiniCloudAPIClient.needsDiscovery(source: nil, username: "listener", hasNewPassword: true))
        var unresolved = source
        unresolved.host = nil
        #expect(InfiniCloudAPIClient.needsDiscovery(source: unresolved, username: "listener", hasNewPassword: false))
    }

    @Test func cloudPresentationUsesPasswordStorageAndWebDAVCapabilities() throws {
        let type = try #require(MusicSourceType(rawValue: "infiniCloud"))
        #expect(type.category == .cloudDrive)
        #expect(type.requiresCredentials && !type.requiresOAuth && !type.requiresHost)
        #expect(type.defaultSSL && type.defaultPort == 443)
        #expect(type.supportsRangeStreaming && type.supportsSidecarWriting && type.supportsFileDeletion)
        #expect(type.libraryFolderPathSemantics == .hierarchical)
        #expect(AudioMetadataWritebackPolicy.embeddedSourceTypes.contains(type))
        #expect(SourcePermanentDeletionPolicy.requiredCredentialStores(for: type, authType: .password) == [.password])
        #expect(SourceDirectorySelectionPolicy.selectableRootPath(for: type, browserPath: "/") == "/")
        #expect(SourceCreationPersistencePolicy.defersUntilValidatedDirectorySelection(for: type))
    }

    @Test func playbackUsesDiscoveredNodeAndNeverIncludesAppKey() async throws {
        let registry = StreamResolverRegistry()
        let source = MusicSource(name: "Music", type: .infiniCloud, host: "ise.infini-cloud.net",
                                 port: 443, username: "listener", basePath: "/dav")
        let song = Song(id: "song", title: "A B", fileFormat: .flac, filePath: "/Music/A B.flac", sourceID: source.id)
        let stream = try await registry.resolve(for: song, source: source,
                                               credential: SourceCredential(username: "listener", password: "app-password"))
        #expect(stream.url.absoluteString == "https://ise.infini-cloud.net/dav/Music/A%20B.flac")
        #expect(stream.headers == ["Authorization": "Basic " + Data("listener:app-password".utf8).base64EncodedString()])
    }
}
