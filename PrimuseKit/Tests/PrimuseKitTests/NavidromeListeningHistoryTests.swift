import Foundation
import Testing
@testable import PrimuseKit

struct NavidromeListeningHistoryTests {
    private static let baseURL = URL(string: "https://[::1]:4533/music")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let login = #"{"id":"user-1","username":"Alice","token":"native-token"}"#
    private static let one = #"{"id":1,"mediaFileId":"song-1","submissionTime":1790000000}"#
    private static let two = #"{"id":2,"mediaFileId":"song-1","submissionTime":1790000000}"#
    private static let three = #"{"id":3,"mediaFileId":"song-2","submissionTime":1780000000}"#

    @Test static func authenticatesWithJSONAndReadsStablePagesIncludingSameSecondReplays() async throws {
        let fixture = Fixture { request, index in
            let url = try #require(request.url)
            #expect(NetworkEndpointIdentity(url: url)?.host == "::1")
            #expect(url.port == 4533)
            if index == 0 {
                #expect(url.path == "/music/auth/login")
                #expect(request.httpMethod == "POST")
                let credentials = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
                #expect(credentials == ["username": "alice", "password": "fixture-password"])
                return response(request, json: login)
            }
            #expect(url.path == "/music/api/scrobble")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpBody == nil)
            let query = query(request)
            #expect(query["_sort"] == "id")
            #expect(query["_order"] == "ASC")
            #expect(query["to"] == "1800000000")
            #expect(query["u"] == nil && query["p"] == nil && query["t"] == nil)
            switch index {
            case 1:
                #expect(query["_start"] == "0" && query["_end"] == "2")
                #expect(request.value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer native-token")
                return response(request, json: "[\(one),\(two)]", total: 3, token: "refreshed-token")
            case 2:
                #expect(query["_start"] == "2" && query["_end"] == "4")
                #expect(request.value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer refreshed-token")
                return response(request, json: "[\(three)]", total: 3)
            default:
                #expect(query["_start"] == "2" && query["_end"] == "3")
                return response(request, json: "[\(three)]", total: 3)
            }
        }
        let snapshot = try await fetch(fixture, pageSize: 2)
        #expect(snapshot.accountID == "user-1")
        #expect(snapshot.entries.map(\.id) == [1, 2, 3])
        #expect(snapshot.entries.map(\.submissionTime) == [1_790_000_000, 1_790_000_000, 1_780_000_000])
        #expect(await fixture.requests.count == 4)
    }

    @Test(arguments: ["[]", "null"]) static func emptyHistoryIsValidEvenWithExistingLifetimeCounters(json: String) async throws {
        let fixture = Fixture { request, index in
            response(request, json: index == 0 ? login : json, total: index == 0 ? nil : 0)
        }
        #expect(try await fetch(fixture).entries.isEmpty)
    }

    @Test(arguments: [401, 403, 404, 405, 501]) static func nativeLoginUnavailableCanFallBack(status: Int) async {
        let fixture = Fixture { request, _ in response(request, status: status, json: "{}") }
        await #expect(throws: NavidromeListeningHistory.Failure.unavailable) { try await fetch(fixture) }
    }

    @Test static func oldNativeAPIWithoutScrobbleResourceCanFallBack() async {
        let fixture = Fixture { request, index in
            response(request, status: index == 0 ? 200 : 404, json: index == 0 ? login : "{}")
        }
        await #expect(throws: NavidromeListeningHistory.Failure.unavailable) { try await fetch(fixture) }
    }

    @Test static func htmlLoginPageCanFallBackWithoutRequestingHistory() async {
        let fixture = Fixture { request, _ in
            response(request, json: "<html>Sign in</html>", mime: "text/html")
        }
        await #expect(throws: NavidromeListeningHistory.Failure.unavailable) { try await fetch(fixture) }
        #expect(await fixture.requests.count == 1)
    }

    @Test static func malformedJSONLoginRemainsAnInvalidResponse() async {
        let fixture = Fixture { request, _ in response(request, json: "{}") }
        await #expect(throws: NavidromeListeningHistory.Failure.invalidResponse) { try await fetch(fixture) }
        #expect(await fixture.requests.count == 1)
    }

    @Test static func htmlFallbackFromOldServerIsNotTreatedAsEmptyHistory() async {
        let fixture = Fixture { request, index in
            response(request, json: index == 0 ? login : "<html>Navidrome</html>", mime: index == 0 ? "application/json" : "text/html")
        }
        await #expect(throws: NavidromeListeningHistory.Failure.unavailable) { try await fetch(fixture) }
    }

    @Test static func aServerFailureMustNotDowngradeHistoryToAggregate() async {
        let fixture = Fixture { request, index in
            response(request, status: index == 0 ? 200 : 500, json: index == 0 ? login : "{}")
        }
        await #expect(throws: NavidromeListeningHistory.Failure.httpStatus(500)) { try await fetch(fixture) }
    }

    @Test static func proxyLoginForAnotherAccountIsRejected() async {
        let fixture = Fixture { request, _ in
            response(request, json: #"{"id":"user-2","username":"bob","token":"native-token"}"#)
        }
        await #expect(throws: NavidromeListeningHistory.Failure.accountMismatch) { try await fetch(fixture) }
    }

    @Test static func missingTotalCountIsNotPublishedAsCompleteHistory() async {
        let fixture = Fixture { request, index in
            response(request, json: index == 0 ? login : "[\(one)]")
        }
        await #expect(throws: NavidromeListeningHistory.Failure.invalidResponse) { try await fetch(fixture) }
    }

    @Test(arguments: [
        #"[{"id":0,"mediaFileId":"song","submissionTime":1790000000}]"#,
        #"[{"id":1,"mediaFileId":"","submissionTime":1790000000}]"#,
        #"[{"id":1,"mediaFileId":"song","submissionTime":0}]"#,
        #"[{"id":1,"mediaFileId":"song","submissionTime":1800000001}]"#,
        #"[{"id":1,"mediaFileId":"song"}]"#,
    ]) static func rejectsInvalidEventsWithoutFillingMissingFields(json: String) async {
        let fixture = Fixture { request, index in
            response(request, json: index == 0 ? login : json, total: index == 0 ? nil : 1)
        }
        await #expect(throws: NavidromeListeningHistory.Failure.invalidResponse) { try await fetch(fixture) }
    }

    @Test static func rejectsExcessiveHistoryInsteadOfTruncatingIt() async {
        let fixture = Fixture { request, index in
            response(request, json: index == 0 ? login : "[\(one)]", total: index == 0 ? nil : 1_000_001)
        }
        await #expect(throws: NavidromeListeningHistory.Failure.invalidResponse) { try await fetch(fixture) }
    }

    @Test static func aChangingCountRetriesTheEntireSnapshotOnce() async throws {
        let fixture = Fixture { request, index in
            switch index {
            case 0: response(request, json: login)
            case 1: response(request, json: "[\(one)]", total: 2)
            case 2: response(request, json: "[\(two)]", total: 3)
            case 3: response(request, json: "[\(one)]", total: 2)
            case 4: response(request, json: "[\(two)]", total: 2)
            default: response(request, json: "[\(two)]", total: 2)
            }
        }
        let snapshot = try await fetch(fixture, pageSize: 1)
        #expect(snapshot.entries.map(\.id) == [1, 2])
        #expect(await fixture.requests.count == 6)
    }

    @Test static func aServerIgnoringOffsetsFailsWithoutReturningPartialOrDuplicateHistory() async {
        let fixture = Fixture { request, index in
            response(request, json: index == 0 ? login : "[\(one)]", total: index == 0 ? nil : 2)
        }
        await #expect(throws: NavidromeListeningHistory.Failure.historyChanged) { try await fetch(fixture, pageSize: 1) }
        #expect(await fixture.requests.count == 5)
    }

    @Test static func finalVerificationDetectsHistoryDeletedAfterLastPage() async {
        let fixture = Fixture { request, index in
            if index == 0 { return response(request, json: login) }
            if index % 2 == 1 { return response(request, json: "[\(one)]", total: 1) }
            return response(request, json: "[]", total: 0)
        }
        await #expect(throws: NavidromeListeningHistory.Failure.historyChanged) { try await fetch(fixture) }
    }

    @Test static func finalVerificationDetectsDeletePlusBackdatedInsertWithUnchangedCount() async {
        let fixture = Fixture { request, index in
            if index == 0 { return response(request, json: login) }
            if index % 2 == 1 { return response(request, json: "[\(one),\(two)]", total: 2) }
            return response(request, json: "[\(three)]", total: 2)
        }
        await #expect(throws: NavidromeListeningHistory.Failure.historyChanged) { try await fetch(fixture) }
        #expect(await fixture.requests.count == 5)
    }

    @Test static func cancellationRemainsACancellation() async {
        let fixture = Fixture { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await fetch(fixture) }
    }

    private static func fetch(_ fixture: Fixture, pageSize: Int = 500) async throws -> NavidromeListeningHistory.Snapshot {
        try await NavidromeListeningHistory.fetch(
            baseURL: baseURL, username: "alice", password: "fixture-password",
            now: now, pageSize: pageSize
        ) { request in try await fixture.load(request) }
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    private static func response(
        _ request: URLRequest, status: Int = 200, json: String,
        total: Int? = nil, token: String? = nil, mime: String = "application/json"
    ) -> (Data, URLResponse) {
        var headers = ["Content-Type": mime]
        if let total { headers["X-Total-Count"] = String(total) }
        if let token { headers["X-ND-Authorization"] = "Bearer \(token)" }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    private actor Fixture {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest, Int) throws -> (Data, URLResponse)

        init(handler: @escaping @Sendable (URLRequest, Int) throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        func load(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            return try handler(request, requests.count - 1)
        }
    }
}
