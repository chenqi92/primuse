import Foundation
import Testing
@testable import PrimuseKit

@Suite("Jellyfin and Emby user admin payloads")
struct MediaServerUserAdminPayloadsTests {
    @Test("Users carry admin, disabled and library limits")
    func users() throws {
        let data = Data("""
        [{"Name":"admin","Id":"a1","LastActivityDate":"2026-11-18T09:12:03.1234567Z",
          "Policy":{"IsAdministrator":true,"IsDisabled":false,"EnableAllFolders":true,"EnabledFolders":[]}},
         {"Name":"kid","Id":"k2","LastLoginDate":"0001-01-01T00:00:00.0000000Z",
          "Policy":{"IsAdministrator":false,"IsDisabled":true,"EnableAllFolders":false,"EnabledFolders":["m1"]}}]
        """.utf8)
        let users = try MediaServerUserAdminPayloads.users(from: data)
        #expect(users.map(\.userName) == ["admin", "kid"])
        #expect(users[0].isAdmin && users[0].libraryIDs == nil && users[0].lastSeenAt != nil)
        #expect(!users[1].isAdmin && users[1].isDisabled && users[1].libraryIDs == ["m1"] && users[1].lastSeenAt == nil)
    }

    @Test("Policy updates keep every field they don't change")
    func policyUpdate() throws {
        let user = Data("""
        {"Name":"kid","Id":"k2","Policy":{"IsAdministrator":false,"EnableAllFolders":true,"EnabledFolders":[],
          "EnableContentDownloading":false,"AuthenticationProviderId":"Default","MaxParentalRating":10}}
        """.utf8)
        let body = try MediaServerUserAdminPayloads.policyUpdate(userData: user, isAdmin: false, libraryIDs: ["m1", "m2"])
        let policy = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(policy["EnableAllFolders"] as? Bool == false)
        #expect(policy["EnabledFolders"] as? [String] == ["m1", "m2"])
        #expect(policy["EnableContentDownloading"] as? Bool == false)
        #expect(policy["AuthenticationProviderId"] as? String == "Default")
        #expect(policy["MaxParentalRating"] as? Int == 10)

        let admin = try MediaServerUserAdminPayloads.policyUpdate(userData: user, isAdmin: true, libraryIDs: ["m1"])
        let adminPolicy = try #require(try JSONSerialization.jsonObject(with: admin) as? [String: Any])
        #expect(adminPolicy["IsAdministrator"] as? Bool == true)
        #expect(adminPolicy["EnableAllFolders"] as? Bool == true)
    }

    @Test("Libraries come from media folders and admin checks read the policy")
    func librariesAndAdmin() throws {
        let folders = Data(#"{"Items":[{"Name":"Music","Id":"m1","CollectionType":"music"},{"Name":"Books","Id":"b1"}],"TotalRecordCount":2}"#.utf8)
        #expect(try MediaServerUserAdminPayloads.libraries(from: folders).map(\.id) == ["m1", "b1"])
        #expect(try MediaServerUserAdminPayloads.isAdministrator(userData: Data(#"{"Policy":{"IsAdministrator":true}}"#.utf8)))
        #expect(throws: ServerAdmin.Failure.invalidResponse) {
            try MediaServerUserAdminPayloads.isAdministrator(userData: Data("{}".utf8))
        }
    }

    @Test("Server refusals map to readable reasons")
    func failures() {
        #expect(MediaServerUserAdminPayloads.failure(status: 400, body: Data("A user with the name 'kid' already exists.".utf8)) == .duplicateName)
        #expect(MediaServerUserAdminPayloads.failure(status: 403, body: Data()) == .notAdmin)
        #expect(MediaServerUserAdminPayloads.failure(status: 404, body: Data()) == .unavailable)
        #expect(MediaServerUserAdminPayloads.failure(status: 500, body: Data("boom".utf8)) == .rejected("boom"))
    }
}
