import Foundation
import Testing
@testable import PrimuseKit

struct STRMDescriptorParserTests {
    @Test func parsesOpenListURLAndExtinfWithoutPersistingAssumptions() throws {
        let data = Data("""
        #EXTM3U
        #EXTINF:245,陈奕迅 - 红玫瑰
        #KODIPROP:mimetype=audio/flac
        https://openlist.example/d/%E9%9F%B3%E4%B9%90/file?id=secret
        """.utf8)

        let descriptor = try STRMDescriptorParser.parse(data)
        #expect(descriptor.format == .flac)
        #expect(descriptor.duration == 245)
        #expect(descriptor.artist == "陈奕迅")
        #expect(descriptor.title == "红玫瑰")
        #expect(descriptor.contentRevision.hasPrefix("strm:"))
        guard case .remote(let url) = descriptor.target else {
            Issue.record("Expected an HTTP target")
            return
        }
        #expect(url.host == "openlist.example")
    }

    @Test func acceptsUTF8BOMAndUsesFirstNonPropertyLine() throws {
        let text = Data("#EXTVLCOPT:http-user-agent=test\r\nhttps://example.com/a.mp3\r\nhttps://example.com/b.flac".utf8)
        let data = Data([0xEF, 0xBB, 0xBF]) + text
        let descriptor = try STRMDescriptorParser.parse(data)
        #expect(descriptor.format == .mp3)
        guard case .remote(let url) = descriptor.target else {
            Issue.record("Expected remote URL")
            return
        }
        #expect(url.lastPathComponent == "a.mp3")
    }

    @Test func selectsFirstValidTargetAndReadsTrailingProperties() throws {
        let descriptor = try STRMDescriptorParser.parse(Data("""
        ftp://example.com/unsupported.flac
        https://example.com/runtime-stream?id=1
        #KODIPROP:mimetype=audio/flac
        https://example.com/later.mp3
        """.utf8))

        #expect(descriptor.format == .flac)
        guard case .remote(let url) = descriptor.target else {
            Issue.record("Expected remote URL")
            return
        }
        #expect(url.path == "/runtime-stream")
    }

    @Test func acceptsUTF16AndSafeRelativeTarget() throws {
        let text = "../audio/album.flac"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let descriptor = try STRMDescriptorParser.parse(data)
        #expect(descriptor.format == .flac)
        guard case .sourcePath(let path) = descriptor.target else {
            Issue.record("Expected source path")
            return
        }
        #expect(path == "../audio/album.flac")
        #expect(STRMSourcePathResolver.resolve(path, relativeTo: "music/links/song.strm") == "music/audio/album.flac")
    }

    @Test func infersFormatFromEncodedQueryFileName() throws {
        let descriptor = try STRMDescriptorParser.parse(
            Data("https://example.com/download?filename=album%2Em4a&token=secret".utf8)
        )
        #expect(descriptor.format == .m4a)
    }

    @Test func rejectsCredentialedAndUnsupportedTargets() {
        #expect(throws: STRMDescriptorError.self) {
            try STRMDescriptorParser.parse(Data("https://user:password@example.com/a.mp3".utf8))
        }
        #expect(throws: STRMDescriptorError.self) {
            try STRMDescriptorParser.parse(Data("file:///private/a.mp3".utf8))
        }
        #expect(throws: STRMDescriptorError.self) {
            try STRMDescriptorParser.parse(Data("https://example.com/no-format".utf8))
        }
    }

    @Test func rejectsOversizedDescriptor() {
        let data = Data(repeating: 0x61, count: STRMDescriptorParser.maximumByteCount + 1)
        #expect(throws: STRMDescriptorError.self) {
            try STRMDescriptorParser.parse(data)
        }
    }

    @Test func revisionChangesOnlyWhenDescriptorBytesChange() throws {
        let first = try STRMDescriptorParser.parse(Data("https://example.com/a.mp3?t=one".utf8))
        let same = try STRMDescriptorParser.parse(Data("https://example.com/a.mp3?t=one".utf8))
        let changed = try STRMDescriptorParser.parse(Data("https://example.com/a.mp3?t=two".utf8))
        #expect(first.contentRevision == same.contentRevision)
        #expect(first.contentRevision != changed.contentRevision)
    }

    @Test func wrapperFingerprintSkipsOnlyReliablyUnchangedDescriptors() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let revision = STRMRevision.songRevision(
            wrapperRevision: "etag-1",
            wrapperSize: 48,
            wrapperModifiedDate: modified,
            contentRevision: "strm:content"
        )
        #expect(STRMRevision.wrapperMatches(
            songRevision: revision,
            wrapperRevision: "etag-1",
            wrapperSize: 48,
            wrapperModifiedDate: modified
        ))
        #expect(!STRMRevision.wrapperMatches(
            songRevision: revision,
            wrapperRevision: "etag-2",
            wrapperSize: 48,
            wrapperModifiedDate: modified
        ))
        #expect(!STRMRevision.wrapperMatches(
            songRevision: revision,
            wrapperRevision: nil,
            wrapperSize: 48,
            wrapperModifiedDate: nil
        ))
    }

    @Test("OpenList prefix-free targets resolve at the origin, not the WebDAV root")
    func resolvesOpenListOriginTarget() throws {
        let wrapper = try #require(URL(string: "https://music.example:5244/dav/strm/album/song.strm"))
        let resolved = try #require(OpenListSTRMTargetResolver.resolve(
            "/d/Ali/Music/song.flac?sign=short-lived",
            wrapperURL: wrapper
        ))
        #expect(resolved.absoluteString == "https://music.example:5244/d/Ali/Music/song.flac?sign=short-lived")
        #expect(OpenListSTRMTargetResolver.resolve("/Music/song.flac", wrapperURL: wrapper) == nil)
        #expect(OpenListSTRMTargetResolver.resolve("/d/../secret.flac", wrapperURL: wrapper) == nil)
    }
}
