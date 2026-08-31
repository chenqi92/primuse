import Foundation
import Testing
@testable import PrimuseKit

@Suite("Tianyi Cloud API boundary")
struct TianyiCloudAPIProtocolTests {
    @Test("Source registration stays closed until every release requirement is satisfied")
    func integrationReadinessFailsClosed() {
        let blocked = TianyiCloudIntegrationReadiness(satisfiedRequirements: [])
        #expect(!blocked.canRegisterSource)
        #expect(blocked.unmetRequirements == TianyiCloudIntegrationRequirement.allCases)

        let ready = TianyiCloudIntegrationReadiness(
            satisfiedRequirements: Set(TianyiCloudIntegrationRequirement.allCases)
        )
        #expect(ready.canRegisterSource)
        #expect(ready.unmetRequirements.isEmpty)

        for missingRequirement in TianyiCloudIntegrationRequirement.allCases {
            var incomplete = Set(TianyiCloudIntegrationRequirement.allCases)
            incomplete.remove(missingRequirement)
            #expect(!TianyiCloudIntegrationReadiness(
                satisfiedRequirements: incomplete
            ).canRegisterSource)
        }
    }

    @Test("Partner signing secrets never reside in the app")
    func credentialResidence() {
        #expect(TianyiCloudCredentialPolicy.requiredResidence(for: .accessToken) == .perSourceKeychain)
        #expect(TianyiCloudCredentialPolicy.requiredResidence(for: .refreshToken) == .perSourceKeychain)
        #expect(TianyiCloudCredentialPolicy.requiredResidence(for: .applicationSecret) == .serverOnly)
        #expect(TianyiCloudCredentialPolicy.requiredResidence(for: .rsaPrivateKey) == .serverOnly)
    }

    @Test("Current list response preserves opaque IDs and mixed integer encodings")
    func decodesOfficialListShape() throws {
        let data = Data(#"""
        {
          "res_code": 0,
          "res_message": "success",
          "fileListAO": {
            "count": "2",
            "fileList": [
              {
                "id": "11420114663140032",
                "name": "album.flac",
                "parentId": 4134713392130879,
                "rev": "20211011105849",
                "size": "788751",
                "md5": "065D9B3479200FC3C85B59D48888E09D",
                "mediaType": "2",
                "createDate": "2021-09-10 02:15:27",
                "lastOpTime": "2021-10-11 10:58:49"
              }
            ],
            "fileListSize": 1,
            "folderList": [
              {
                "id": 4134713392130880,
                "name": "Music",
                "parentId": "4134713392130879",
                "rev": 20220511181339
              }
            ]
          },
          "lastRev": 20220511152728
        }
        """#.utf8)

        let response = try JSONDecoder().decode(TianyiCloudListFilesResponse.self, from: data)
        let catalog = try #require(response.catalog)
        let file = try #require(catalog.files.first)
        let folder = try #require(catalog.folders.first)

        #expect(response.isSuccess)
        #expect(response.resultCode == "0")
        #expect(response.lastRevision == "20220511152728")
        #expect(catalog.totalItemCount == 2)
        #expect(catalog.receivedItemCount == 2)
        #expect(catalog.reportedFileCount == 1)
        #expect(file.providerID == "11420114663140032")
        #expect(file.parentID?.rawValue == "4134713392130879")
        #expect(file.revision == "20211011105849")
        #expect(file.size == 788_751)
        #expect(file.mediaType == 2)
        #expect(folder.providerID == "4134713392130880")
        #expect(folder.parentID?.rawValue == "4134713392130879")
        #expect(folder.revision == "20220511181339")
    }

    @Test("Provider error codes remain available without inventing undocumented mappings")
    func decodesProviderError() throws {
        let data = Data(#"{"res_message":"Internal error","res_code":"InternalError"}"#.utf8)
        let response = try JSONDecoder().decode(TianyiCloudListFilesResponse.self, from: data)

        #expect(!response.isSuccess)
        #expect(response.resultCode == "InternalError")
        #expect(response.resultMessage == "Internal error")
        #expect(response.catalog == nil)
    }

    @Test("Page numbers advance only while a well-formed snapshot has more items")
    func safePagination() throws {
        let data = Data(#"""
        {
          "res_code": "0",
          "fileListAO": {
            "count": 5,
            "folderList": [{"id": 10, "name": "A"}],
            "fileList": [{"id": 20, "name": "a.flac"}],
            "fileListSize": 1
          },
          "lastRev": "202608310001"
        }
        """#.utf8)
        let response = try JSONDecoder().decode(TianyiCloudListFilesResponse.self, from: data)
        let page = TianyiCloudCatalogPage(response: response, pageNumber: 1, pageSize: 2)

        #expect(page.nextPageNumber == 2)
        #expect(TianyiCloudCatalogPagingPolicy.nextPageNumber(
            currentPage: 3,
            pageSize: 2,
            receivedItemCount: 1,
            totalItemCount: 5
        ) == nil)
        #expect(TianyiCloudCatalogPagingPolicy.nextPageNumber(
            currentPage: 1,
            pageSize: 2,
            receivedItemCount: 3,
            totalItemCount: 5
        ) == nil)
        #expect(TianyiCloudCatalogPagingPolicy.nextPageNumber(
            currentPage: 1,
            pageSize: 2,
            receivedItemCount: 1,
            totalItemCount: nil
        ) == nil)
        #expect(TianyiCloudCatalogPagingPolicy.nextPageNumber(
            currentPage: 2,
            pageSize: 2,
            receivedItemCount: 1,
            totalItemCount: 5
        ) == nil)
    }

    @Test("Storage revision is a snapshot hint rather than a claimed delta cursor")
    func lastRevisionDoesNotEnableDeltaSync() throws {
        let data = Data(#"{"res_code":0,"lastRev":"202608310001"}"#.utf8)
        let response = try JSONDecoder().decode(TianyiCloudListFilesResponse.self, from: data)

        #expect(!TianyiCloudCatalogSyncPolicy.supportsNativeDeltaFeed)
        #expect(TianyiCloudCatalogSyncPolicy.snapshotRevisionHint(from: response) == "202608310001")
    }

    @Test("Byte-range playback requires an exact two-byte 206 probe")
    func rangeStreamingFailsClosed() {
        #expect(TianyiCloudPlaybackPolicy.strategyForProbe(
            statusCode: 206,
            contentRange: "bytes 0-1/12831499",
            contentLength: 2,
            receivedBodyLength: 2
        ) == .verifiedByteRange(totalLength: 12_831_499))
        #expect(TianyiCloudPlaybackPolicy.strategyForProbe(
            statusCode: 200,
            contentRange: "bytes 0-1/12831499",
            contentLength: 2,
            receivedBodyLength: 2
        ) == .controlledFullFileCache)
        #expect(TianyiCloudPlaybackPolicy.strategyForProbe(
            statusCode: 206,
            contentRange: "bytes 0-12831498/12831499",
            contentLength: 12_831_499,
            receivedBodyLength: 12_831_499
        ) == .controlledFullFileCache)
        #expect(TianyiCloudPlaybackPolicy.strategyForProbe(
            statusCode: 206,
            contentRange: "bytes 0-1/12831499",
            contentLength: 2,
            receivedBodyLength: 1
        ) == .controlledFullFileCache)
    }
}
