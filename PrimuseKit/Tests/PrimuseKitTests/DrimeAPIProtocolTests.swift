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
        #expect(query["parentIds"] == "4815")
        #expect(query["folderId"] == nil)
        #expect(query["page"] == "2")
        #expect(query["perPage"] == "75")
        #expect(DrimeAPIProtocol.entryURL(id: "../token") == nil)

        let entryURL = try #require(DrimeAPIProtocol.entryURL(id: "4815"))
        let entryComponents = try #require(URLComponents(url: entryURL, resolvingAgainstBaseURL: false))
        #expect(entryComponents.path == "/api/v1/file-entries/4815")
        #expect(entryComponents.queryItems == [URLQueryItem(name: "workspaceId", value: "0")])
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
        #expect(response.user?.id == "15843")
        #expect(response.user?.displayName == "Listener")
    }

    @Test("Logged user accepts the null response used for rejected API keys")
    func decodeRejectedLoggedUser() throws {
        let response = try DrimeAPIProtocol.decodeLoggedUser(Data(#"{"user":null}"#.utf8))
        #expect(response.user == nil)
    }

    @Test("Mutation endpoints stay inside the documented API base")
    func mutationURLs() {
        #expect(DrimeAPIProtocol.uploadsURL.absoluteString
                == "https://app.drime.cloud/api/v1/uploads")
        #expect(DrimeAPIProtocol.deleteEntriesURL.absoluteString
                == "https://app.drime.cloud/api/v1/file-entries/delete")
        #expect(DrimeAPIProtocol.restoreEntriesURL.absoluteString
                == "https://app.drime.cloud/api/v1/file-entries/restore")
        #expect(DrimeAPIProtocol.multipartCreateURL.absoluteString
                == "https://app.drime.cloud/api/v1/s3/multipart/create")
        #expect(DrimeAPIProtocol.multipartSignPartsURL.absoluteString
                == "https://app.drime.cloud/api/v1/s3/multipart/batch-sign-part-urls")
        #expect(DrimeAPIProtocol.multipartCompleteURL.absoluteString
                == "https://app.drime.cloud/api/v1/s3/multipart/complete")
        #expect(DrimeAPIProtocol.multipartAbortURL.absoluteString
                == "https://app.drime.cloud/api/v1/s3/multipart/abort")
        #expect(DrimeAPIProtocol.createS3EntryURL.absoluteString
                == "https://app.drime.cloud/api/v1/s3/entries")
    }

    @Test("Sidecar pseudo paths map only numeric source IDs")
    func sidecarReferences() throws {
        #expect(DrimeAPIProtocol.sidecarReference(from: "485529678-cover.jpg")
                == DrimeSidecarReference(sourceEntryID: "485529678", suffix: "-cover.jpg"))
        #expect(DrimeAPIProtocol.sidecarReference(from: "485529678.lrc")
                == DrimeSidecarReference(sourceEntryID: "485529678", suffix: ".lrc"))
        #expect(DrimeAPIProtocol.sidecarReference(from: "485529678.ttml")
                == DrimeSidecarReference(sourceEntryID: "485529678", suffix: ".ttml"))
        #expect(DrimeAPIProtocol.sidecarReference(from: "../485529678.lrc") == nil)
        #expect(DrimeAPIProtocol.sidecarReference(from: "track.lrc") == nil)
        #expect(DrimeAPIProtocol.sidecarReference(from: "485529678.jpg") == nil)
    }

    @Test("Upload metadata preserves Unicode and rejects header injection")
    func uploadMetadata() throws {
        let cover = try #require(DrimeAPIProtocol.uploadMetadata(for: "周杰伦-cover.jpg"))
        #expect(cover.fileExtension == "jpg")
        #expect(cover.mimeType == "image/jpeg")

        let lyrics = try #require(DrimeAPIProtocol.uploadMetadata(for: "晴天.lrc"))
        #expect(lyrics.fileExtension == "lrc")
        #expect(lyrics.mimeType == "text/plain; charset=utf-8")

        let ttml = try #require(DrimeAPIProtocol.uploadMetadata(for: "晴天.ttml"))
        #expect(ttml.fileExtension == "ttml")
        #expect(ttml.mimeType == "application/ttml+xml")

        #expect(DrimeAPIProtocol.uploadMetadata(for: "bad\r\nname.lrc") == nil)
        #expect(DrimeAPIProtocol.uploadMetadata(for: "../name.lrc") == nil)
        #expect(DrimeAPIProtocol.multipartThreshold == 5_242_880)
        #expect(DrimeAPIProtocol.multipartPartSize == 5_242_880)
    }

    @Test("Mutation bodies require an explicit success without item errors")
    func mutationSuccessConfirmation() {
        #expect(DrimeAPIProtocol.confirmsSuccess(Data(#"{"status":"success"}"#.utf8)))
        #expect(!DrimeAPIProtocol.confirmsSuccess(Data(#"{"status":"error"}"#.utf8)))
        #expect(!DrimeAPIProtocol.confirmsSuccess(Data(#"{"status":"success","errors":{"1":"denied"}}"#.utf8)))
        #expect(!DrimeAPIProtocol.confirmsSuccess(Data("{}".utf8)))
    }

    @Test("HTTP failures distinguish authentication, permissions and throttling")
    func httpFailureKinds() {
        #expect(DrimeAPIProtocol.failureKind(forHTTPStatusCode: 200) == nil)
        #expect(DrimeAPIProtocol.failureKind(forHTTPStatusCode: 201) == nil)
        #expect(DrimeAPIProtocol.failureKind(forHTTPStatusCode: 401) == .invalidToken)
        #expect(DrimeAPIProtocol.failureKind(forHTTPStatusCode: 403) == .insufficientPermissions)
        #expect(DrimeAPIProtocol.failureKind(forHTTPStatusCode: 429) == .rateLimited)
        #expect(DrimeAPIProtocol.failureKind(forHTTPStatusCode: 500) == .other(500))
    }
}
