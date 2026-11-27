import Foundation
import Testing
@testable import PrimuseKit

@Test func subsonicAttributeWrappedJSONIsFlattenedRecursively() throws {
    let input = Data(#"""
    {
      "subsonic-response": {
        "_attributes": {"status": "ok", "version": "1.16.1"},
        "albumList2": {
          "album": [
            {"_attributes": {"id": "album-1", "name": "QA Album"}}
          ]
        }
      }
    }
    """#.utf8)

    let normalized = try SubsonicResponseCompatibility.normalizedJSONData(input)
    let root = try #require(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
    let response = try #require(root["subsonic-response"] as? [String: Any])
    let albumList = try #require(response["albumList2"] as? [String: Any])
    let albums = try #require(albumList["album"] as? [[String: Any]])

    #expect(response["status"] as? String == "ok")
    #expect(response["version"] as? String == "1.16.1")
    #expect(albums.first?["id"] as? String == "album-1")
    #expect(albums.first?["name"] as? String == "QA Album")
}

@Test func subsonicStandardJSONRemainsUsable() throws {
    let input = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
    let normalized = try SubsonicResponseCompatibility.normalizedJSONData(input)
    let root = try #require(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
    let response = try #require(root["subsonic-response"] as? [String: Any])

    #expect(response["status"] as? String == "ok")
    #expect(response["version"] as? String == "1.16.1")
}

@Test func subsonicEncodedPasswordRetryOnlyHandlesUnsupportedToken() {
    #expect(SubsonicResponseCompatibility.shouldRetryWithEncodedPassword(
        errorCode: 41,
        alreadyUsingEncodedPassword: false
    ))
    #expect(!SubsonicResponseCompatibility.shouldRetryWithEncodedPassword(
        errorCode: 40,
        alreadyUsingEncodedPassword: false
    ))
    #expect(!SubsonicResponseCompatibility.shouldRetryWithEncodedPassword(
        errorCode: 41,
        alreadyUsingEncodedPassword: true
    ))
}
