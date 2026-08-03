import Foundation
import Testing
@testable import PrimuseKit

@Suite("Drime API protocol")
struct DrimeAPIProtocolTests {
    @Test("Listing requests preserve pagination and folder scope")
    func listingURL() throws {
        let url = try #require(DrimeAPIProtocol.listingURL(folderID: "/4815/", page: 2, perPage: 75))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.path == "/api/v1/drive/file-entries")
        #expect(query["workspaceId"] == "0")
        #expect(query["folderId"] == "4815")
        #expect(query["page"] == "2")
        #expect(query["perPage"] == "75")
        #expect(DrimeAPIProtocol.entryURL(id: "../token") == nil)
    }

    @Test("Listing response accepts Drime numeric fields")
    func decodeListing() throws {
        let data = Data(#"""
        {
          "data": [
            {
              "id": 485529677,
              "name": "Music",
              "type": "folder",
              "file_size": 0,
              "parent_id": null,
              "updated_at": "2024-01-15T10:30:00.000000Z"
            },
            {
              "id": "485529678",
              "name": "track.flac",
              "type": "audio",
              "file_size": "2048576",
              "parent_id": 485529677,
              "url": "secure/uploads/3260",
              "file_hash": "revision-1"
            }
          ],
          "current_page": 1,
          "last_page": 3,
          "per_page": 50,
          "total": 102
        }
        """#.utf8)

        let listing = try DrimeAPIProtocol.decodeListing(data)
        #expect(listing.currentPage == 1)
        #expect(listing.lastPage == 3)
        #expect(listing.total == 102)
        #expect(listing.data[0].id == "485529677")
        #expect(listing.data[0].isDirectory)
        #expect(listing.data[0].modifiedDate != nil)
        #expect(listing.data[1].fileSize == 2_048_576)
        #expect(listing.data[1].parentID == "485529677")
        #expect(listing.data[1].revision == "revision-1")
    }

    @Test("Entry response resolves authenticated media URL")
    func decodeEntryAndMediaURL() throws {
        let data = Data(#"""
        {
          "status": "success",
          "fileEntry": {
            "id": 3260,
            "name": "track.flac",
            "type": "audio",
            "file_size": 111863,
            "url": "secure/uploads/3260",
            "hash": "MzI2MHxwYWRkaQ"
          }
        }
        """#.utf8)

        let response = try DrimeAPIProtocol.decodeEntry(data)
        #expect(response.fileEntry.id == "3260")
        #expect(DrimeAPIProtocol.mediaURL(reference: response.fileEntry.url)?.absoluteString
                == "https://app.drime.cloud/secure/uploads/3260")
        #expect(CloudDriveStreamResolver.parseDrimeURL(data)?.absoluteString
                == "https://app.drime.cloud/secure/uploads/3260")
        #expect(DrimeAPIProtocol.mediaURL(reference: "https://example.com/track.flac") == nil)
        #expect(DrimeAPIProtocol.mediaURL(reference: "//example.com/track.flac") == nil)
    }

    @Test("Logged user accepts numeric account ID")
    func decodeLoggedUser() throws {
        let data = Data(#"""
        {"user":{"id":15843,"display_name":"Listener","email":"listener@example.com"}}
        """#.utf8)

        let response = try DrimeAPIProtocol.decodeLoggedUser(data)
        #expect(response.user.id == "15843")
        #expect(response.user.displayName == "Listener")
    }
}
