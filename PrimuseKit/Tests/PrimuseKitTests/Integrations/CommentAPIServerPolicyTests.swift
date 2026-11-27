import Foundation
import Testing
@testable import PrimuseKit

@Suite("CommentAPIServerPolicy address & requestURL")
struct CommentAPIServerPolicyURLTests {
    @Test("normalizedAddress accepts http/https, ports, existing queries, and placeholders")
    func normalizedAddressValid() {
        #expect(CommentAPIServerPolicy.normalizedAddress("https://example.com/comments") == "https://example.com/comments")
        #expect(CommentAPIServerPolicy.normalizedAddress("  http://192.168.1.5:3000/api/comments?key=1  ") == "http://192.168.1.5:3000/api/comments?key=1")
        #expect(
            CommentAPIServerPolicy.normalizedAddress("https://example.com/comments/{{sort}}?q={{title}}&a={{artist}}")
                == "https://example.com/comments/{{sort}}?q={{title}}&a={{artist}}"
        )
    }

    @Test("normalizedAddress rejects unsupported schemes, missing host, or malformed braces")
    func normalizedAddressInvalid() {
        #expect(CommentAPIServerPolicy.normalizedAddress("ftp://example.com/comments") == nil)
        #expect(CommentAPIServerPolicy.normalizedAddress("example.com/comments") == nil)
        #expect(CommentAPIServerPolicy.normalizedAddress("   ") == nil)
        #expect(CommentAPIServerPolicy.normalizedAddress("https://{{title}}.example.com/comments") == nil)
    }

    @Test("requestURL appends standard query parameters and preserves existing query")
    func requestURLAppendsQuery() throws {
        let url = try #require(CommentAPIServerPolicy.requestURL(
            address: "https://example.com/comments?token=abc",
            title: "A+B",
            artist: "Singer",
            album: "Album",
            duration: 215.8,
            sort: .latest,
            page: 2,
            limit: 30,
            cursor: "next_2"
        ))
        #expect(url.absoluteString.contains("token=abc&"))
        #expect(url.absoluteString.contains("title=A%2BB"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(map["token"] == "abc")
        #expect(map["artist"] == "Singer")
        #expect(map["album"] == "Album")
        #expect(map["duration"] == "215")
        #expect(map["sort"] == "latest")
        #expect(map["page"] == "2")
        #expect(map["limit"] == "30")
        #expect(map["cursor"] == "next_2")
    }

    @Test("requestURL expands URL template placeholders without duplicating parameters")
    func requestURLTemplateExpansion() throws {
        let url = try #require(CommentAPIServerPolicy.requestURL(
            address: "https://example.com/v1/{{sort}}/comments?song={{title}}&by={{artist}}&p={{page}}&n={{limit}}",
            title: "Hello & World",
            artist: "Jane/Doe",
            album: nil,
            duration: nil,
            sort: .hot,
            page: 3,
            limit: 15
        ))
        #expect(url.path == "/v1/hot/comments")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(map["song"] == "Hello & World")
        #expect(map["by"] == "Jane/Doe")
        #expect(map["p"] == "3")
        #expect(map["n"] == "15")
        #expect(map["title"] == nil)
    }
}

@Suite("CommentAPIServerPolicy response parsing")
struct CommentAPIServerPolicyResponseTests {
    private func classify(_ status: Int, _ body: String, contentType: String? = "application/json") -> CommentAPIServerPolicy.ResponseClassification {
        CommentAPIServerPolicy.classifyResponse(statusCode: status, contentType: contentType, body: Data(body.utf8))
    }

    @Test("parses standard object with hotComments, comments, replies, timestamps, and metadata")
    func parsesRichStandardPayload() {
        let json = """
        {
          "total": 420,
          "hasMore": true,
          "nextCursor": "cur-2",
          "hotComments": [
            {
              "id": "h1",
              "user": { "id": "u1", "nickname": "Alice", "avatarUrl": "https://example.com/a.jpg" },
              "content": "First hot comment",
              "time": 1730000000000,
              "likedCount": 12500,
              "ipLocation": { "location": "Shanghai" },
              "isPinned": true,
              "replies": [
                {
                  "id": "r1",
                  "user": { "id": "u2", "nickname": "Bob" },
                  "content": "Totally agree",
                  "replyTo": "Alice"
                }
              ]
            }
          ],
          "comments": [
            {
              "commentId": 9001,
              "author": "Charlie",
              "text": "Fresh listen today",
              "createdAt": "2026-10-01T12:30:00Z",
              "likes": 8
            }
          ]
        }
        """
        guard case .comments(let page) = classify(200, json) else {
            Issue.record("Expected .comments")
            return
        }
        #expect(page.total == 420)
        #expect(page.hasMore == true)
        #expect(page.nextCursor == "cur-2")
        #expect(page.hotComments.count == 1)
        #expect(page.comments.count == 1)
        let hot = page.hotComments[0]
        #expect(hot.id == "h1")
        #expect(hot.authorName == "Alice")
        #expect(hot.authorID == "u1")
        #expect(hot.avatarURL == "https://example.com/a.jpg")
        #expect(hot.likedCount == 12500)
        #expect(hot.location == "Shanghai")
        #expect(hot.isPinned == true)
        #expect(hot.isHot == true)
        #expect(hot.timestamp != nil)
        #expect(hot.replies.count == 1)
        #expect(hot.replies[0].replyToAuthorName == "Alice")
        let regular = page.comments[0]
        #expect(regular.id == "9001")
        #expect(regular.authorName == "Charlie")
        #expect(regular.content == "Fresh listen today")
        #expect(regular.timestamp != nil)
        #expect(regular.likedCount == 8)
    }

    @Test("parses wrapped data envelope and root array")
    func parsesEnvelopeAndArray() {
        let wrapped = #"{"data":{"total":1,"more":false,"list":[{"id":"1","author":"M","content":"Hi"}]}}"#
        guard case .comments(let page1) = classify(200, wrapped) else {
            Issue.record("Expected .comments for wrapped data")
            return
        }
        #expect(page1.comments.count == 1)
        #expect(page1.total == 1)

        let array = #"[{"author":"A","content":"Line 1"},{"author":"B","content":"Line 2"}]"#
        guard case .comments(let page2) = classify(200, array) else {
            Issue.record("Expected .comments for root array")
            return
        }
        #expect(page2.comments.count == 2)
    }

    @Test("handles HTTP status, empty results, HTML rejection, and size limit")
    func handlesErrorsAndBoundaries() {
        #expect(classify(404, "") == .empty)
        #expect(classify(204, "") == .empty)
        #expect(classify(500, "err") == .failed(statusCode: 500))
        #expect(classify(200, "<!DOCTYPE html><html><body>Hello</body></html>", contentType: "text/html") == .invalidFormat)
        #expect(classify(200, #"{"total":0,"comments":[]}"#) == .empty)
        let oversize = Data(repeating: 0x20, count: CommentAPIServerPolicy.maximumBodyBytes + 1)
        #expect(CommentAPIServerPolicy.classifyResponse(statusCode: 200, contentType: "application/json", body: oversize) == .invalidFormat)
    }
}

@Suite("SongCommentModeration & Player Integration")
struct SongCommentModerationAndIntegrationTests {
    @Test("filters hidden comments and blocked authors including nested replies")
    func moderationFiltering() {
        let items = [
            SongCommentItem(
                id: "c1",
                authorName: "Alice",
                authorID: "u1",
                content: "Keep me",
                replies: [
                    SongCommentReply(id: "r1", authorName: "SpamBot", authorID: "u-spam", content: "Buy now"),
                    SongCommentReply(id: "r2", authorName: "Friend", authorID: "u2", content: "Nice!"),
                ]
            ),
            SongCommentItem(id: "c2", authorName: "SpamBot", authorID: "u-spam", content: "Spam"),
            SongCommentItem(id: "c3", authorName: "Bob", content: "Hide me"),
        ]
        var moderation = SongCommentModeration()
        moderation.hideComment(id: "c3")
        moderation.blockAuthor(key: items[1].authorBlockKey, displayName: "SpamBot")

        let filtered = moderation.filter(items)
        #expect(filtered.map(\.id) == ["c1"])
        #expect(filtered[0].replies.map(\.id) == ["r2"])
    }

    @Test("carousel skips comments panel when no comment server is configured")
    func carouselCommentsVisibilityGate() {
        var config = NowPlayingCarouselConfiguration.default
        config.insert(.comments, on: .trailing)
        #expect(config.trailing.first == .comments)

        let withoutServers = config.visible(
            cardSettings: NowPlayingCarouselCardSettings(),
            in: NowPlayingCarouselCardContext(hasCommentServers: false)
        )
        #expect(!withoutServers.trailing.contains(.comments))

        let withServers = config.visible(
            cardSettings: NowPlayingCarouselCardSettings(),
            in: NowPlayingCarouselCardContext(hasCommentServers: true)
        )
        #expect(withServers.trailing.contains(.comments))
    }

    @Test("NowPlayingControlLayout supports comments button placement, removal, and menu deduplication")
    func controlLayoutCommentsAction() {
        let placed = NowPlayingControlLayout.default.placing(.comments, at: .bar(3))
        #expect(placed.bar.contains(.comments))
        #expect(placed.menuSuppressed(on: .portrait).contains(.comments))

        let decoded = NowPlayingControlLayout.decode(placed.encoded())
        #expect(decoded.bar.contains(.comments))

        let stripped = decoded.removing(.comments)
        #expect(!stripped.bar.contains(.comments))
        #expect(!stripped.menuSuppressed(on: .portrait).contains(.comments))
    }

    @Test("LANSettingsTransferPolicy allows comment server value and keychain secret")
    func lanSettingsTransferAllowsComments() {
        #expect(LANSettingsTransferPolicy.category(forValueKey: LANSettingsTransferPolicy.commentAPIServersKey) == .commentServers)
        #expect(LANSettingsTransferPolicy.category(forSecretAccount: "comments.apiServer.abc123.authorization") == .commentServers)
    }

    @Test("compactLikeCount formats positive counts and hides zero or negative values")
    func compactLikeCountFormatting() {
        #expect(CommentAPIServerPolicy.compactLikeCount(0, locale: Locale(identifier: "en_US")).isEmpty)
        #expect(CommentAPIServerPolicy.compactLikeCount(-5, locale: Locale(identifier: "en_US")).isEmpty)
        #expect(CommentAPIServerPolicy.compactLikeCount(42, locale: Locale(identifier: "en_US")) == "42")
        #expect(!CommentAPIServerPolicy.compactLikeCount(12_500, locale: Locale(identifier: "en_US")).isEmpty)
        #expect(!CommentAPIServerPolicy.compactLikeCount(12_500, locale: Locale(identifier: "zh_Hans")).isEmpty)
    }
}
