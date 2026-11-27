import Foundation
import Testing
@testable import PrimuseKit

@Suite("Navidrome admin")
struct NavidromeAdminTests {
    private actor Recorder {
        var requests: [URLRequest] = []
        func append(_ request: URLRequest) { requests.append(request) }
    }

    private static let base = URL(string: "https://music.example.com/")!

    private static func response(_ status: Int, _ body: String, headers: [String: String] = [:]) -> (Data, URLResponse) {
        var fields = ["Content-Type": "application/json"]
        fields.merge(headers) { _, new in new }
        return (Data(body.utf8), HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: fields)!)
    }

    @Test("Login reads the admin flag and refuses another account")
    func login() async throws {
        let session = try await NavidromeAdmin.login(baseURL: Self.base, username: "Admin", password: "pw") { request in
            #expect(request.url?.path == "/auth/login")
            #expect(request.httpMethod == "POST")
            return Self.response(200, #"{"id":"u1","username":"admin","isAdmin":true,"token":"t1"}"#)
        }
        #expect(session.isAdmin)
        #expect(session.userID == "u1")

        await #expect(throws: NavidromeAdmin.Failure.accountMismatch) {
            _ = try await NavidromeAdmin.login(baseURL: Self.base, username: "admin", password: "pw") { _ in
                Self.response(200, #"{"id":"u2","username":"guest","isAdmin":false,"token":"t"}"#)
            }
        }
        await #expect(throws: NavidromeAdmin.Failure.authenticationFailed) {
            _ = try await NavidromeAdmin.login(baseURL: Self.base, username: "admin", password: "bad") { _ in
                Self.response(401, #"{"error":"Invalid username or password"}"#)
            }
        }
    }

    @Test("Users list sends the native header and follows token refresh")
    func users() async throws {
        var session = NavidromeAdmin.Session(userID: "u1", username: "admin", isAdmin: true, token: "t1")
        let recorder = Recorder()
        let users = try await NavidromeAdmin.users(baseURL: Self.base, session: &session) { request in
            await recorder.append(request)
            return Self.response(200, """
            [{"id":"u1","userName":"admin","name":"Admin","email":"","isAdmin":true,
              "lastLoginAt":"2026-11-01T10:00:00.123456789+08:00","lastAccessAt":null,
              "libraries":[{"id":1,"name":"Music","path":"/music"}]},
             {"id":"u2","userName":"xiaoyu","name":"小雨","isAdmin":false,"lastLoginAt":"0001-01-01T00:00:00Z"}]
            """, headers: ["X-ND-Authorization": "Bearer t2"])
        }
        let request = try #require(await recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer t1")
        #expect(request.url?.path == "/api/user")
        #expect(session.token == "t2")
        #expect(users.map(\.userName) == ["admin", "xiaoyu"])
        #expect(users[0].lastLoginAt != nil)
        #expect(users[0].libraries == [NavidromeAdmin.Library(id: 1, name: "Music", path: "/music")])
        #expect(users[1].lastLoginAt == nil)
        #expect(users[1].libraries == nil)
    }

    @Test("Non-admin sessions never reach the server")
    func notAdmin() async {
        var session = NavidromeAdmin.Session(userID: "u2", username: "xiaoyu", isAdmin: false, token: "t")
        await #expect(throws: NavidromeAdmin.Failure.notAdmin) {
            _ = try await NavidromeAdmin.users(baseURL: Self.base, session: &session) { _ in
                Issue.record("request sent for a non-admin session")
                return Self.response(200, "[]")
            }
        }
    }

    @Test("Validation errors come back as the server's reason")
    func rejected() async {
        var session = NavidromeAdmin.Session(userID: "u1", username: "admin", isAdmin: true, token: "t")
        let newUser = NavidromeAdmin.NewUser(userName: "admin", name: "Dup", password: "pw")
        await #expect(throws: NavidromeAdmin.Failure.rejected(status: 400, message: "userName: ra.validation.unique")) {
            _ = try await NavidromeAdmin.createUser(newUser, baseURL: Self.base, session: &session) { _ in
                Self.response(400, #"{"errors":{"userName":"ra.validation.unique"}}"#)
            }
        }
    }

    @Test("Servers before multi-library support report no libraries")
    func oldServerLibraries() async throws {
        var session = NavidromeAdmin.Session(userID: "u1", username: "admin", isAdmin: true, token: "t")
        let libraries = try await NavidromeAdmin.libraries(baseURL: Self.base, session: &session) { _ in
            Self.response(404, "404 page not found")
        }
        #expect(libraries == nil)
    }

    @Test("Password reset is sent only when given, and the admin cannot delete itself")
    func updateAndDelete() async throws {
        var session = NavidromeAdmin.Session(userID: "u1", username: "admin", isAdmin: true, token: "t")
        let recorder = Recorder()
        let user = NavidromeAdmin.User(id: "u2", userName: "xiaoyu", name: "小雨", email: "", isAdmin: false)
        try await NavidromeAdmin.updateUser(user, newPassword: "new-pass", baseURL: Self.base, session: &session) { request in
            await recorder.append(request)
            return Self.response(200, "{}")
        }
        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/user/u2")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["password"] as? String == "new-pass")
        #expect(body["currentPassword"] == nil)

        await #expect(throws: NavidromeAdmin.Failure.rejected(status: 400, message: nil)) {
            try await NavidromeAdmin.deleteUser(id: "u1", baseURL: Self.base, session: &session) { _ in
                Self.response(200, "{}")
            }
        }
    }
}
