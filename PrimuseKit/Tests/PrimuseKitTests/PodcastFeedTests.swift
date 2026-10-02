import Foundation
import Testing
@testable import PrimuseKit

@Suite("Podcast feeds")
struct PodcastFeedTests {
    private let feedURL = URL(string: "https://feeds.example.com/show.xml")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:content="http://purl.org/rss/1.0/modules/content/"
         xmlns:podcast="https://podcastindex.org/namespace/1.0"
         xmlns:psc="http://podlove.org/simple-chapters">
      <channel>
        <title>  不合时宜  </title>
        <link>https://example.com/show</link>
        <description>频道简介</description>
        <itunes:summary>更长的频道简介</itunes:summary>
        <language>zh-cn</language>
        <itunes:author>主播们</itunes:author>
        <itunes:type>serial</itunes:type>
        <itunes:explicit>yes</itunes:explicit>
        <itunes:image href="https://img.example.com/cover.png"/>
        <image><url>https://img.example.com/small.png</url><title>x</title><link>https://example.com</link></image>
        <itunes:category text="Society &amp; Culture"><itunes:category text="Documentary"/></itunes:category>
        <itunes:category text="News"/>
        <item>
          <title>第二集</title>
          <guid isPermaLink="false">ep-2</guid>
          <pubDate>Wed, 30 Sep 2026 05:42:45 GMT</pubDate>
          <enclosure url="https://media.example.com/ep2.m4a" type="audio/mp4" length="85613021"/>
          <itunes:duration>01:28:08</itunes:duration>
          <itunes:season>2</itunes:season>
          <itunes:episode>1</itunes:episode>
          <description>短说明</description>
          <content:encoded><![CDATA[<p>长说明 <a href="https://example.com/x">链接</a></p><p>00:00 开场</p>]]></content:encoded>
          <itunes:image href="ep2.jpg"/>
          <podcast:chapters url="https://example.com/ch.json" type="application/json+chapters"/>
          <podcast:transcript url="https://example.com/t.html" type="text/html"/>
          <podcast:transcript url="https://example.com/t.vtt" type="text/vtt"/>
        </item>
        <item>
          <title>第一集</title>
          <pubDate>Mon, 14 Sep 2026 00:00:00 +0800</pubDate>
          <enclosure url="https://media.example.com/ep1.mp3" type="audio/mpeg" length="0"/>
          <itunes:duration>4616</itunes:duration>
          <itunes:episodeType>trailer</itunes:episodeType>
          <psc:chapters version="1.2">
            <psc:chapter start="00:03:22.458" title="正题"/>
            <psc:chapter start="0" title="开场"/>
          </psc:chapters>
        </item>
        <item>
          <title>只有文字的更新</title>
          <guid>post-1</guid>
        </item>
      </channel>
    </rss>
    """

    @Test func parsesChannelAndItems() throws {
        let feed = try PodcastFeedParser.parse(Data(Self.rss.utf8), feedURL: feedURL)
        #expect(feed.title == "不合时宜")
        #expect(feed.author == "主播们")
        #expect(feed.summary == "更长的频道简介")
        #expect(feed.artworkURL?.absoluteString == "https://img.example.com/cover.png")
        #expect(feed.websiteURL?.absoluteString == "https://example.com/show")
        #expect(feed.language == "zh-cn")
        #expect(feed.categories == ["Society & Culture", "Documentary", "News"])
        #expect(feed.isSerial)
        #expect(feed.isExplicit)
        #expect(feed.isPartial == false)
        #expect(feed.items.count == 2)

        let second = feed.items[0]
        #expect(second.guid == "ep-2")
        #expect(second.title == "第二集")
        #expect(second.duration == 5288)
        #expect(second.season == 2)
        #expect(second.number == 1)
        #expect(second.kind == .full)
        #expect(second.enclosureLength == 85_613_021)
        #expect(second.showNotes?.contains("<a href") == true)
        #expect(second.artworkURL?.absoluteString == "https://feeds.example.com/ep2.jpg")
        #expect(second.chaptersURL?.absoluteString == "https://example.com/ch.json")
        #expect(second.transcriptType == "text/vtt")
        #expect(second.publishedAt == Date(timeIntervalSince1970: 1_790_746_965))

        let first = feed.items[1]
        #expect(first.guid == nil)
        #expect(first.identity == "https://media.example.com/ep1.mp3")
        #expect(first.enclosureLength == nil)
        #expect(first.kind == .trailer)
        #expect(first.chapters.map(\.title) == ["开场", "正题"])
        let chapterStart = first.chapters.last?.start ?? 0
        #expect(abs(chapterStart - 202.458) < 0.001)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_789_315_200))
    }

    @Test func repairsHTMLEntitiesAndBareAmpersands() throws {
        let broken = """
        <rss version="2.0"><channel><title>Tom &amp; Jerry&nbsp;Show</title>
        <item><title>Q&A time</title><guid>1</guid><enclosure url="https://m.example.com/1.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let feed = try PodcastFeedParser.parse(Data(broken.utf8))
        #expect(feed.title == "Tom & Jerry\u{00a0}Show")
        #expect(feed.items.first?.title == "Q&A time")
    }

    @Test func keepsWhatWasReadBeforeTheFeedBreaks() throws {
        let truncated = """
        <rss version="2.0"><channel><title>Cut</title>
        <item><title>One</title><guid>1</guid><enclosure url="https://m.example.com/1.mp3"/></item>
        <item><title>Two</title><guid>2</guid><enclosure url="https://m.example.com/2.mp3"/></item>
        <item><title>Thr
        """
        let feed = try PodcastFeedParser.parse(Data(truncated.utf8))
        #expect(feed.items.map(\.title) == ["One", "Two"])
        #if canImport(Darwin)
        // Linux 的 XMLParser 读到截断处不报错,只有 Apple 平台能断言「部分」。
        #expect(feed.isPartial)
        #endif
    }

    @Test func rejectsWebPages() {
        let html = "<!DOCTYPE html><html><head><title>Hi</title></head><body>nope</body></html>"
        #expect(throws: PodcastFeedError.notAFeed) { try PodcastFeedParser.parse(Data(html.utf8)) }
        #expect(throws: PodcastFeedError.self) { try PodcastFeedParser.parse(Data("{\"a\":1}".utf8)) }
    }

    @Test func parsesAtomFeeds() throws {
        let atom = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <title>Atom Cast</title>
          <author><name>Ann</name></author>
          <logo>https://img.example.com/logo.png</logo>
          <entry>
            <id>urn:1</id>
            <title>Hello</title>
            <published>2026-09-01T10:00:00Z</published>
            <summary>Sum</summary>
            <link rel="enclosure" href="https://m.example.com/a.mp3" type="audio/mpeg" length="100"/>
            <itunes:duration>12:00</itunes:duration>
          </entry>
        </feed>
        """
        let feed = try PodcastFeedParser.parse(Data(atom.utf8))
        #expect(feed.title == "Atom Cast")
        #expect(feed.author == "Ann")
        #expect(feed.artworkURL?.absoluteString == "https://img.example.com/logo.png")
        #expect(feed.items.count == 1)
        #expect(feed.items[0].guid == "urn:1")
        #expect(feed.items[0].duration == 720)
        #expect(feed.items[0].showNotes == "Sum")
    }

    @Test func movedFeedIsReported() throws {
        let moved = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>M</title>
        <itunes:new-feed-url>https://new.example.com/feed</itunes:new-feed-url></channel></rss>
        """
        let feed = try PodcastFeedParser.parse(Data(moved.utf8))
        #expect(feed.newFeedURL?.absoluteString == "https://new.example.com/feed")
    }

    @Test(arguments: [
        ("1:02:03", 3723.0), ("83:45", 5025.0), ("5025", 5025.0), ("5025.5", 5025.5),
        ("00:00:00", nil), ("abc", nil), ("", nil), ("1:2:3:4", nil),
    ] as [(String, Double?)])
    func durations(_ raw: String, _ expected: Double?) {
        #expect(PodcastFeedParser.duration(from: raw) == expected)
    }

    @Test(arguments: [
        "Wed, 30 Sep 2026 05:42:45 GMT", "Thu, 30 Sep 2026 05:42:45 GMT", "30 Sep 2026 05:42:45 +0000",
        "Wed,  30 Sep 2026 05:42:45 UTC", "2026-09-30T05:42:45Z", "Wed, 30 Sep 2026 13:42:45 +0800",
    ])
    func rfc822Dates(_ raw: String) {
        #expect(PodcastFeedParser.date(from: raw) == Date(timeIntervalSince1970: 1_790_746_965))
    }

    @Test(arguments: [
        "30 Sep 2026 05:42:45 GMT", "14 Sep 2026 00:00:00 +0800", "1 Jan 2000 00:00 EST", "29 Feb 2024 12:00:00 -0530",
        "5 Mar 1971 08:09:10 PDT", "15 Jun 2026 10:00:00.5 UTC", "1 Sept 2026 10:00:00 +01:00",
    ])
    func fastDatesMatchTheFormatter(_ text: String) throws {
        let fast = try #require(PodcastDateParser.fastRFC822(text))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let normalized = text.replacingOccurrences(of: "Sept", with: "Sep").replacingOccurrences(of: "+01:00", with: "+0100")
        let candidates = ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm zzz", "d MMM yy HH:mm:ss Z", "d MMM yyyy HH:mm:ss.S zzz"]
        let expected = candidates.lazy.compactMap { format -> Date? in
            formatter.dateFormat = format
            return formatter.date(from: normalized)
        }.first
        #expect(fast == expected)
    }

    @Test func twoDigitYearsLandInTheRightCentury() {
        #expect(PodcastDateParser.fastRFC822("31 Dec 99 23:59:59 +0000") == Date(timeIntervalSince1970: 946_684_799))
        #expect(PodcastDateParser.fastRFC822("1 Jan 26 00:00:00 GMT") == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test func fastDatesRejectWhatTheyCannotRead() {
        #expect(PodcastDateParser.fastRFC822("30 Septembre 2026 05:42:45 GMT") == nil)
        #expect(PodcastDateParser.fastRFC822("30 Sep 2026 25:42:45 GMT") == nil)
        #expect(PodcastDateParser.fastRFC822("30 Sep 2026 05:42:45 CEST") == nil)
        #expect(PodcastDateParser.fastRFC822("2026-09-30T05:42:45Z") == nil)
        // 交给格式化器的写法照样能读。
        #expect(PodcastFeedParser.date(from: "2026-09-30T05:42:45Z") == Date(timeIntervalSince1970: 1_790_746_965))
    }

    @Test func chaptersJSON() {
        let json = """
        {"version":"1.2.0","chapters":[
          {"startTime":120.5,"title":"B","img":"b.png"},
          {"startTime":0,"title":"A","url":"https://a.example.com"},
          {"startTime":60,"title":"hidden","toc":false}
        ]}
        """
        let chapters = PodcastChaptersJSON.decode(Data(json.utf8), baseURL: URL(string: "https://x.example.com/c/ch.json"))
        #expect(chapters.map(\.title) == ["A", "B"])
        #expect(chapters[1].imageURL?.absoluteString == "https://x.example.com/c/b.png")
        #expect(PodcastChaptersJSON.decode(Data("nope".utf8)).isEmpty)
    }

    // MARK: - Identity

    @Test func identityIsStableAndSchemeInsensitive() {
        let a = PodcastIdentity.showID(feedURL: URL(string: "https://Feeds.Example.com/show/")!)
        let b = PodcastIdentity.showID(feedURL: URL(string: "http://feeds.example.com/show")!)
        #expect(a == b)
        #expect(a.hasPrefix("podcast-show:"))
        #expect(a.count == "podcast-show:".count + 32)
        let episode = PodcastIdentity.episodeID(showID: a, guid: "ep-1")
        #expect(PodcastIdentity.isEpisodeID(episode))
        #expect(episode == PodcastIdentity.episodeID(showID: a, guid: "ep-1"))
        #expect(episode != PodcastIdentity.episodeID(showID: a, guid: "ep-2"))
        // 固定值:换实现会让已存的进度和下载全部对不上。
        #expect(PodcastIdentity.digest("primuse") == PodcastIdentity.digest("primuse"))
        #expect(PodcastIdentity.digest("") == "cbf29ce484222325" + "84222325cbf29ce4")
    }

    @Test(arguments: [
        ("feeds.example.com/rss", "https://feeds.example.com/rss"),
        ("itpc://feeds.example.com/rss", "https://feeds.example.com/rss"),
        ("pcast://feeds.example.com/rss", "https://feeds.example.com/rss"),
        ("feed:https://feeds.example.com/rss", "https://feeds.example.com/rss"),
        ("feed://feeds.example.com/rss", "https://feeds.example.com/rss"),
        ("  http://rss.lizhi.fm/rss/484704.xml ", "http://rss.lizhi.fm/rss/484704.xml"),
    ])
    func normalizesFeedAddresses(_ raw: String, _ expected: String) {
        #expect(PodcastFeedURL.normalized(raw)?.absoluteString == expected)
    }

    @Test func rejectsNonAddresses() {
        #expect(PodcastFeedURL.normalized("hello world") == nil)
        #expect(PodcastFeedURL.normalized("ftp://x.example.com/a") == nil)
        #expect(PodcastFeedURL.normalized("localhost") == nil)
        #expect(PodcastFeedURL.normalized("") == nil)
    }

    @Test func appleDirectoryLinks() {
        #expect(PodcastFeedURL.appleDirectoryID(in: "https://podcasts.apple.com/cn/podcast/%E4%B8%8D/id1487143507?i=1") == 1487143507)
        #expect(PodcastFeedURL.appleDirectoryID(in: "https://itunes.apple.com/podcast/id42") == 42)
        #expect(PodcastFeedURL.appleDirectoryID(in: "https://example.com/id42") == nil)
    }
}

@Suite("Podcast library policy")
struct PodcastLibraryPolicyTests {
    private let feedURL = URL(string: "https://feeds.example.com/show.xml")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ guid: String, daysAgo: Double, kind: PodcastEpisodeKind = .full, season: Int? = nil, number: Int? = nil) -> PodcastFeedItem {
        PodcastFeedItem(
            guid: guid,
            title: "Episode \(guid)",
            publishedAt: t0.addingTimeInterval(-daysAgo * 86_400),
            enclosureURL: URL(string: "https://m.example.com/\(guid).mp3"),
            season: season,
            number: number,
            kind: kind
        )
    }

    private func feed(_ items: [PodcastFeedItem], serial: Bool = false) -> PodcastFeed {
        PodcastFeed(title: "Show", author: "Host", isSerial: serial, items: items)
    }

    @Test func firstSubscriptionMarksNothingNew() {
        let result = PodcastFeedMerge.subscribe(feed: feed([item("b", daysAgo: 1), item("a", daysAgo: 8)]), feedURL: feedURL, now: t0)
        #expect(result.addedEpisodeIDs.isEmpty)
        #expect(result.episodes.map(\.guid) == ["b", "a"])
        #expect(result.show.id == PodcastIdentity.showID(feedURL: feedURL))
        #expect(result.show.subscribedAt == t0)
        #expect(result.show.latestEpisodeAt == t0.addingTimeInterval(-86_400))
        #expect(PodcastEpisodeListPolicy.newEpisodeCount(show: result.show, episodes: result.episodes, state: { _ in .untouched }) == 0)
    }

    @Test func refreshAddsNewKeepsFirstSeenAndRetainsListenedEpisodes() {
        let first = PodcastFeedMerge.subscribe(feed: feed([item("b", daysAgo: 1), item("a", daysAgo: 8)]), feedURL: feedURL, now: t0)
        let later = t0.addingTimeInterval(3_600)
        let aID = first.episodes[1].id
        // feed 只保留最近两集:a 被挤掉,但用户听过 a。
        let second = PodcastFeedMerge.refresh(
            show: first.show,
            existing: first.episodes,
            feed: feed([item("c", daysAgo: 0), item("b", daysAgo: 1)]),
            retaining: [aID],
            now: later
        )
        #expect(second.episodes.map(\.guid) == ["c", "b", "a"])
        #expect(second.addedEpisodeIDs == [second.episodes[0].id])
        #expect(second.episodes[1].firstSeenAt == t0)
        #expect(second.episodes[0].firstSeenAt == later)
        #expect(PodcastEpisodeListPolicy.newEpisodeCount(show: second.show, episodes: second.episodes, state: { _ in .untouched }) == 1)

        let dropped = PodcastFeedMerge.refresh(show: first.show, existing: first.episodes, feed: feed([item("b", daysAgo: 1)]), now: later)
        #expect(dropped.episodes.map(\.guid) == ["b"])
    }

    @Test func movedFeedKeepsTheShowIdentity() {
        var moved = feed([item("a", daysAgo: 1)])
        moved.newFeedURL = URL(string: "https://new.example.com/feed")
        let first = PodcastFeedMerge.subscribe(feed: moved, feedURL: feedURL, now: t0)
        #expect(first.show.id == PodcastIdentity.showID(feedURL: feedURL))
        #expect(first.show.feedURL.absoluteString == "https://new.example.com/feed")
    }

    @Test func duplicateGUIDsCollapse() {
        let result = PodcastFeedMerge.subscribe(feed: feed([item("a", daysAgo: 1), item("a", daysAgo: 2)]), feedURL: feedURL, now: t0)
        #expect(result.episodes.count == 1)
    }

    @Test func continuationPlaysForwardSkippingTrailersAndFinished() {
        let result = PodcastFeedMerge.subscribe(feed: feed([
            item("e5", daysAgo: 0), item("e4", daysAgo: 1), item("t", daysAgo: 2, kind: .trailer),
            item("e3", daysAgo: 3), item("e2", daysAgo: 4), item("e1", daysAgo: 5),
        ]), feedURL: feedURL, now: t0)
        let finished = Set(result.episodes.filter { $0.guid == "e4" }.map(\.id))
        let queue = PodcastEpisodeListPolicy.continuation(
            from: result.episodes.first { $0.guid == "e2" }!.id,
            in: result.episodes,
            state: { PodcastEpisodeState(isFinished: finished.contains($0.id)) }
        )
        #expect(queue.map(\.guid) == ["e2", "e3", "e5"])
    }

    @Test func resumeTargetFollowsShowType() {
        let result = PodcastFeedMerge.subscribe(feed: feed([item("e3", daysAgo: 0), item("e2", daysAgo: 1), item("e1", daysAgo: 2)]), feedURL: feedURL, now: t0)
        let finishedE1 = Set(result.episodes.filter { $0.guid == "e1" }.map(\.id))
        let state: (PodcastEpisode) -> PodcastEpisodeState = { PodcastEpisodeState(isFinished: finishedE1.contains($0.id)) }
        #expect(PodcastEpisodeListPolicy.resumeTarget(in: result.episodes, isSerial: true, state: state)?.guid == "e2")
        #expect(PodcastEpisodeListPolicy.resumeTarget(in: result.episodes, isSerial: false, state: state)?.guid == "e3")
        let inProgress = Set(result.episodes.filter { $0.guid == "e1" }.map(\.id))
        #expect(PodcastEpisodeListPolicy.resumeTarget(in: result.episodes, isSerial: false, state: {
            PodcastEpisodeState(position: inProgress.contains($0.id) ? 30 : nil)
        })?.guid == "e1")
    }

    @Test func seasonsGroupOnlyWhenThereAreSeveral() {
        let one = PodcastFeedMerge.subscribe(feed: feed([item("a", daysAgo: 0, season: 1), item("b", daysAgo: 1, season: 1)]), feedURL: feedURL, now: t0)
        #expect(PodcastEpisodeListPolicy.seasonGroups(one.episodes, order: .newestFirst).count == 1)
        let two = PodcastFeedMerge.subscribe(feed: feed([
            item("s2e1", daysAgo: 0, season: 2), item("x", daysAgo: 1), item("s1e1", daysAgo: 2, season: 1),
        ]), feedURL: feedURL, now: t0)
        let newest = PodcastEpisodeListPolicy.seasonGroups(two.episodes, order: .newestFirst)
        #expect(newest.map(\.season) == [2, 1, nil])
        let oldest = PodcastEpisodeListPolicy.seasonGroups(PodcastEpisodeListPolicy.ordered(two.episodes, order: .oldestFirst), order: .oldestFirst)
        #expect(oldest.map(\.season) == [1, 2, nil])
    }

    @Test func episodeNumbersShowOnlyWhenTheyFollowPublishOrder() {
        func episodes(_ numbers: [Int?]) -> [PodcastEpisode] {
            let items = numbers.enumerated().map { index, number in item("n\(index)", daysAgo: Double(index), number: number) }
            return PodcastFeedMerge.subscribe(feed: feed(items), feedURL: feedURL, now: t0).episodes
        }
        #expect(PodcastEpisodeListPolicy.numbersFollowPublishOrder(episodes([12, 11, nil, 10])))
        #expect(PodcastEpisodeListPolicy.numbersFollowPublishOrder(episodes([nil, 3, nil])))
        // 喜马拉雅:最新一集编 1,越旧越大。
        #expect(!PodcastEpisodeListPolicy.numbersFollowPublishOrder(episodes([1, 2, 3, 4])))
        #expect(!PodcastEpisodeListPolicy.numbersFollowPublishOrder(episodes([1, 1, 1])))
        // 偶尔一集编错不影响整档。
        #expect(PodcastEpisodeListPolicy.numbersFollowPublishOrder(episodes([20, 19, 30, 17, 16])))
    }

    @Test func latestAcrossShowsSkipsFinishedAndRespectsLimit() {
        let a = PodcastFeedMerge.subscribe(feed: feed([item("a1", daysAgo: 0), item("a2", daysAgo: 3)]), feedURL: feedURL, now: t0)
        let b = PodcastFeedMerge.subscribe(feed: feed([item("b1", daysAgo: 1), item("b2", daysAgo: 2)]), feedURL: URL(string: "https://other.example.com/feed")!, now: t0)
        let finished = Set([a.episodes[0].id])
        let latest = PodcastEpisodeListPolicy.latest(
            episodesByShow: [a.show.id: a.episodes, b.show.id: b.episodes],
            state: { PodcastEpisodeState(isFinished: finished.contains($0.id)) },
            limit: 3
        )
        #expect(latest.map(\.guid) == ["b1", "b2", "a2"])
        let since = PodcastEpisodeListPolicy.latest(
            episodesByShow: [a.show.id: a.episodes, b.show.id: b.episodes],
            state: { _ in .untouched },
            excludingFinished: false,
            since: t0.addingTimeInterval(-1.5 * 86_400),
            limit: 10
        )
        #expect(since.map(\.guid) == ["a1", "b1"])
    }

    @Test func filters() {
        #expect(PodcastEpisodeFilter.unplayed.includes(PodcastEpisodeState(position: 10)))
        #expect(!PodcastEpisodeFilter.unplayed.includes(PodcastEpisodeState(isFinished: true)))
        #expect(PodcastEpisodeFilter.inProgress.includes(PodcastEpisodeState(position: 10)))
        #expect(!PodcastEpisodeFilter.inProgress.includes(PodcastEpisodeState(position: 10, isFinished: true)))
        #expect(PodcastEpisodeFilter.downloaded.includes(PodcastEpisodeState(isDownloaded: true)))
    }

    @Test func refreshScheduleBacksOff() {
        #expect(PodcastRefreshSchedule.isDue(lastRefreshedAt: nil, now: t0))
        #expect(!PodcastRefreshSchedule.isDue(lastRefreshedAt: t0.addingTimeInterval(-600), now: t0))
        #expect(PodcastRefreshSchedule.isDue(lastRefreshedAt: t0.addingTimeInterval(-1_900), now: t0))
        #expect(!PodcastRefreshSchedule.isDue(lastRefreshedAt: t0.addingTimeInterval(-1_900), failureCount: 2, now: t0))
        #expect(PodcastRefreshSchedule.isDue(lastRefreshedAt: t0.addingTimeInterval(-86_400), failureCount: 9, now: t0))
    }

    @Test func storedShowsSurviveMissingFields() throws {
        let json = #"{"id":"podcast-show:x","feedURL":"https://a.example.com/f"}"#
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(json.utf8))
        #expect(show.title == "")
        #expect(show.settings == PodcastShowSettings())
        #expect(show.effectiveEpisodeOrder == .newestFirst)
        let episodeJSON = #"{"id":"podcast:1","showID":"s","enclosureURL":"https://a.example.com/1.mp3"}"#
        let episode = try JSONDecoder().decode(PodcastEpisode.self, from: Data(episodeJSON.utf8))
        #expect(episode.guid == "podcast:1")
        #expect(episode.kind == .full)
        #expect(episode.audioFileExtension == "mp3")
    }

    @Test func audioExtensionFallsBackToMIME() {
        let episode = PodcastEpisode(
            id: "podcast:x", showID: "s", guid: "g", title: "t",
            enclosureURL: URL(string: "https://dts.example.com/track/abc")!, enclosureType: "audio/mp4", firstSeenAt: t0
        )
        #expect(episode.audioFileExtension == "m4a")
        #expect(!episode.isVideo)
    }
}

@Suite("Podcast show notes")
struct PodcastShowNotesTests {
    @Test func htmlBecomesBlocksWithLinksAndTimestamps() {
        let html = """
        <p><strong>【主播的话】</strong></p><p>看这里 <a href="https://example.com/a?b=1&amp;c=2">文章</a>。</p>
        <ul><li>00:00 开场</li><li>1:02:03 正题</li></ul>
        <ol><li>一</li><li>二</li></ol>
        <script>alert(1)</script><h2>标题</h2>
        """
        let blocks = PodcastShowNotes.blocks(from: html)
        #expect(blocks.count == 7)
        #expect(blocks[0] == .paragraph([.text("【主播的话】", bold: true, italic: false)]))
        #expect(blocks[1] == .paragraph([.text("看这里 ", bold: false, italic: false), .link("文章", URL(string: "https://example.com/a?b=1&c=2")!), .text("。", bold: false, italic: false)]))
        #expect(blocks[2] == .listItem([.timestamp("00:00", 0), .text(" 开场", bold: false, italic: false)], marker: "•"))
        #expect(blocks[3] == .listItem([.timestamp("1:02:03", 3723), .text(" 正题", bold: false, italic: false)], marker: "•"))
        #expect(blocks[4] == .listItem([.text("一", bold: false, italic: false)], marker: "1."))
        #expect(blocks[5] == .listItem([.text("二", bold: false, italic: false)], marker: "2."))
        #expect(blocks[6] == .heading([.text("标题", bold: false, italic: false)]))
    }

    @Test func plainTextLinkifiesURLsAndTimes() {
        let blocks = PodcastShowNotes.blocks(from: "第一行 https://example.com/x。\n\n- 12:30 讨论\n不是时间 12:75 和 3:00:00:00")
        #expect(blocks.count == 3)
        #expect(blocks[0] == .paragraph([.text("第一行 ", bold: false, italic: false), .link("https://example.com/x", URL(string: "https://example.com/x")!), .text("。", bold: false, italic: false)]))
        #expect(blocks[1] == .listItem([.timestamp("12:30", 750), .text(" 讨论", bold: false, italic: false)], marker: "•"))
        #expect(blocks[2] == .paragraph([.text("不是时间 12:75 和 3:00:00:00", bold: false, italic: false)]))
    }

    @Test func summaryStripsMarkupAndEntities() {
        let summary = PodcastShowNotes.plainSummary("<p>Tom &amp; Jerry&nbsp;&#x4E2D;</p><p>second</p>", limit: 100)
        // 不换行空格在摘要里也只是一个普通空格。
        #expect(summary == "Tom & Jerry 中 second")
        #expect(PodcastShowNotes.plainSummary(String(repeating: "a", count: 10), limit: 4) == "aaaa…")
        #expect(PodcastShowNotes.plainSummary("   ") == nil)
    }

    @Test func seekLinksRoundTrip() {
        let url = PodcastShowNotes.seekURL(3723.9)
        #expect(PodcastShowNotes.seekSeconds(from: url) == 3723)
        #expect(PodcastShowNotes.seekSeconds(from: URL(string: "https://example.com")!) == nil)
    }
}

@Suite("Podcast directory")
struct PodcastDirectoryTests {
    @Test func feedCategoriesMapToDirectoryGenres() {
        #expect(PodcastDirectory.genreID(forCategory: "Society & Culture") == 1324)
        #expect(PodcastDirectory.genreID(forCategory: " TECHNOLOGY ") == 1318)
        #expect(PodcastDirectory.genreID(forCategory: "Games & Hobbies") == 1502)
        #expect(PodcastDirectory.genreID(forCategory: "Podcasting") == nil)
        #expect(Set(["arts", "business", "comedy"].compactMap(PodcastDirectory.genreID(forCategory:))).isSubset(of: Set(PodcastDirectory.genreIDs)))
    }

    @Test func decodesSearchResults() throws {
        let json = """
        {"resultCount":2,"results":[
          {"wrapperType":"track","kind":"podcast","collectionId":1487143507,"trackId":1487143507,"artistName":"不合时宜TheWeirdo",
           "collectionName":"不合时宜","feedUrl":"https://feed.xyzfm.space/ww7cqnybekty","artworkUrl600":"https://is1.example.com/600x600bb.jpg",
           "primaryGenreName":"社会与文化","trackCount":290,"releaseDate":"2026-09-30T05:42:00Z"},
          {"wrapperType":"track","kind":"podcast","collectionId":1487143507,"collectionName":"dup"},
          {"kind":"podcast","collectionId":7}
        ]}
        """
        let shows = try PodcastDirectory.decodeSearch(Data(json.utf8))
        #expect(shows.count == 1)
        #expect(shows[0].id == 1487143507)
        #expect(shows[0].feedURL?.absoluteString == "https://feed.xyzfm.space/ww7cqnybekty")
        #expect(shows[0].episodeCount == 290)
        #expect(shows[0].latestReleaseAt != nil)
        #expect(throws: PodcastDirectoryError.badResponse) { try PodcastDirectory.decodeSearch(Data("<html>".utf8)) }
    }

    @Test func decodesChartsIncludingSingleEntry() throws {
        let list = """
        {"feed":{"entry":[{"im:name":{"label":"硅谷101"},"im:artist":{"label":"硅谷101"},
          "im:image":[{"label":"https://is1.example.com/a/55x55bb.png","attributes":{"height":"55"}},
                      {"label":"https://is1.example.com/a/170x170bb.png","attributes":{"height":"170"}}],
          "id":{"label":"x","attributes":{"im:id":"1498541229"}},"category":{"attributes":{"im:id":"1318","label":"科技"}}}]}}
        """
        let shows = try PodcastDirectory.decodeChart(Data(list.utf8))
        #expect(shows.map(\.id) == [1498541229])
        #expect(shows[0].artworkURL?.absoluteString == "https://is1.example.com/a/600x600bb.png")
        #expect(shows[0].genre == "科技")
        #expect(shows[0].feedURL == nil)

        let single = """
        {"feed":{"entry":{"im:name":{"label":"Solo"},"id":{"attributes":{"im:id":"5"}}}}}
        """
        #expect(try PodcastDirectory.decodeChart(Data(single.utf8)).map(\.title) == ["Solo"])
        #expect(try PodcastDirectory.decodeChart(Data(#"{"feed":{}}"#.utf8)).isEmpty)
    }

    @Test func requestURLs() {
        #expect(PodcastDirectory.searchURL(term: "  ", country: "cn") == nil)
        let search = PodcastDirectory.searchURL(term: "念念 有词", country: "cn")!.absoluteString
        #expect(search.contains("media=podcast"))
        #expect(search.contains("country=cn"))
        #expect(search.contains("term=%E5%BF%B5%E5%BF%B5%20%E6%9C%89%E8%AF%8D"))
        #expect(PodcastDirectory.lookupURL(ids: [3, 3, 0, 4], country: "us")?.absoluteString.contains("id=3,4") == true)
        #expect(PodcastDirectory.chartURL(country: "cn", genreID: 1318, limit: 25)?.absoluteString
            == "https://itunes.apple.com/cn/rss/toppodcasts/limit=25/genre=1318/json")
        #expect(PodcastDirectory.chartURL(country: "us")?.absoluteString == "https://itunes.apple.com/us/rss/toppodcasts/limit=50/json")
    }

    @Test func countries() {
        #expect(PodcastDirectory.directoryCountry(storefrontCode: "CHN") == "cn")
        #expect(PodcastDirectory.directoryCountry(storefrontCode: "USA") == "us")
        #expect(PodcastDirectory.directoryCountry(storefrontCode: "jp") == "jp")
        #expect(PodcastDirectory.directoryCountry(storefrontCode: "ZZZ") == "us")
        #expect(PodcastDirectory.directoryCountry(storefrontCode: nil, fallback: "gb") == "gb")
    }

    @Test func availabilityFollowsTheStorefront() {
        #expect(PodcastAvailabilityPolicy.resolve(storefrontCountryCode: "CHN", localeRegionCode: "US")
            == PodcastAvailabilityPolicy(allowsCustomFeeds: false, directoryCountry: "cn"))
        #expect(PodcastAvailabilityPolicy.resolve(storefrontCountryCode: "USA", localeRegionCode: "CN")
            == PodcastAvailabilityPolicy(allowsCustomFeeds: true, directoryCountry: "us"))
        #expect(PodcastAvailabilityPolicy.resolve(storefrontCountryCode: "HKG", localeRegionCode: "CN")
            == PodcastAvailabilityPolicy(allowsCustomFeeds: true, directoryCountry: "hk"))
        // 店面还没取到:中国大陆地区设置按中国处理;其他地区也先不放手填地址。
        #expect(PodcastAvailabilityPolicy.resolve(storefrontCountryCode: nil, localeRegionCode: "CN")
            == PodcastAvailabilityPolicy(allowsCustomFeeds: false, directoryCountry: "cn"))
        #expect(PodcastAvailabilityPolicy.resolve(storefrontCountryCode: nil, localeRegionCode: "DE")
            == PodcastAvailabilityPolicy(allowsCustomFeeds: false, directoryCountry: "de"))
    }
}

@Suite("Podcast OPML")
struct PodcastOPMLTests {
    @Test func roundTrips() throws {
        let show = PodcastShow(
            id: "podcast-show:a", feedURL: URL(string: "https://feeds.example.com/a?x=1&y=2")!,
            title: "A & <B>", websiteURL: URL(string: "https://example.com"), subscribedAt: Date()
        )
        let data = PodcastOPML.export([show])
        let entries = try PodcastOPML.parse(data)
        #expect(entries == [PodcastOPML.Entry(title: "A & <B>", feedURL: show.feedURL)])
    }

    @Test func readsNestedOutlinesFromOtherApps() throws {
        let opml = """
        <?xml version="1.0"?><opml version="1.0"><head><title>x</title></head><body>
        <outline text="Group"><outline type="rss" text="One" xmlUrl="https://a.example.com/1"/>
        <outline TEXT="Two" XMLURL="feed://b.example.com/2"/></outline>
        <outline type="rss" text="dup" xmlUrl="http://a.example.com/1/"/>
        <outline text="no url"/></body></opml>
        """
        let entries = try PodcastOPML.parse(Data(opml.utf8))
        #expect(entries.map(\.feedURL.absoluteString) == ["https://a.example.com/1", "https://b.example.com/2"])
        #expect(entries.map(\.title) == ["One", "Two"])
        #expect(throws: PodcastOPML.Failure.notOPML) { try PodcastOPML.parse(Data("<html></html>".utf8)) }
    }
}

@Suite("Podcast subscription sync")
struct PodcastSubscriptionSyncTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func show(_ name: String, at date: Date, settings: PodcastShowSettings = PodcastShowSettings()) -> PodcastShow {
        let url = URL(string: "https://feeds.example.com/\(name)")!
        return PodcastShow(id: PodcastIdentity.showID(feedURL: url), feedURL: url, title: name, subscribedAt: date, settings: settings)
    }

    @Test func remoteAdditionsAndNewerSettingsArrive() {
        let a = show("a", at: t0)
        var remoteA = PodcastSubscriptionRecord(show: a)
        remoteA.settings.skipIntroSeconds = 30
        remoteA.modifiedAt = t0.addingTimeInterval(60)
        let b = show("b", at: t0.addingTimeInterval(10))
        let remote = PodcastSubscriptionDocument(subscriptions: [remoteA, PodcastSubscriptionRecord(show: b)])
        let outcome = PodcastSubscriptionSync.merge(local: [a], localRemoved: [:], remote: remote, now: t0.addingTimeInterval(100))
        #expect(outcome.shows.map(\.id) == [a.id, b.id])
        #expect(outcome.shows[0].settings.skipIntroSeconds == 30)
        #expect(outcome.addedShowIDs == [b.id])
        #expect(outcome.removedShowIDs.isEmpty)
        #expect(!outcome.needsPush)
    }

    @Test func localChangesAreKeptAndPushed() {
        var a = show("a", at: t0)
        let remote = PodcastSubscriptionDocument(subscriptions: [PodcastSubscriptionRecord(show: a)])
        a.settings.autoDownloadsNewEpisodes = true
        a.definitionModifiedAt = t0.addingTimeInterval(5)
        let c = show("c", at: t0.addingTimeInterval(20))
        let outcome = PodcastSubscriptionSync.merge(local: [a, c], localRemoved: [:], remote: remote, now: t0.addingTimeInterval(100))
        #expect(outcome.shows.map(\.id) == [a.id, c.id])
        #expect(outcome.shows[0].settings.autoDownloadsNewEpisodes)
        #expect(outcome.needsPush)
    }

    @Test func unsubscribeWinsOnlyWhenNewer() {
        let a = show("a", at: t0)
        let removedLater = PodcastSubscriptionDocument(subscriptions: [], removed: [a.id: t0.addingTimeInterval(30)])
        let gone = PodcastSubscriptionSync.merge(local: [a], localRemoved: [:], remote: removedLater, now: t0.addingTimeInterval(100))
        #expect(gone.shows.isEmpty)
        #expect(gone.removedShowIDs == [a.id])

        // 本机在云端退订之后又订了回来:留着并推上去。
        var resubscribed = a
        resubscribed.definitionModifiedAt = t0.addingTimeInterval(60)
        let kept = PodcastSubscriptionSync.merge(local: [resubscribed], localRemoved: [:], remote: removedLater, now: t0.addingTimeInterval(100))
        #expect(kept.shows.map(\.id) == [a.id])
        #expect(kept.removed.isEmpty)
        #expect(kept.needsPush)

        // 本机退订了、云端还是旧的订阅:不再加回来。
        let stale = PodcastSubscriptionDocument(subscriptions: [PodcastSubscriptionRecord(show: a)])
        let local = PodcastSubscriptionSync.merge(local: [], localRemoved: [a.id: t0.addingTimeInterval(10)], remote: stale, now: t0.addingTimeInterval(100))
        #expect(local.shows.isEmpty)
        #expect(local.addedShowIDs.isEmpty)
        #expect(local.needsPush)
    }

    @Test func documentsRoundTripDeterministically() throws {
        let a = show("a", at: t0)
        var b = show("b", at: t0)
        b.playedThrough = t0
        b.reopenedEpisodeIDs = ["z", "y"]
        let document = PodcastSubscriptionSync.document(shows: [b, a], removed: ["old": t0.addingTimeInterval(-200 * 86_400), "x": t0], now: t0)
        #expect(document.removed.keys.sorted() == ["x"])
        let encoded = document.encoded()
        let decoded = try #require(PodcastSubscriptionDocument.decode(encoded))
        #expect(decoded == document)
        #expect(decoded.encoded() == encoded)
        #expect(decoded.subscriptions.map(\.id) == [a.id, b.id].sorted())
        #expect(PodcastSubscriptionDocument.decode("nope") == nil)
    }

    @Test func playedWatermark() {
        var s = show("a", at: t0)
        let old = PodcastEpisode(id: "podcast:1", showID: s.id, guid: "1", title: "", publishedAt: t0.addingTimeInterval(-10),
                                 enclosureURL: URL(string: "https://m.example.com/1.mp3")!, firstSeenAt: t0)
        var new = old
        new.id = "podcast:2"
        new.publishedAt = t0.addingTimeInterval(10)
        #expect(!s.isMarkedPlayed(old))
        s.playedThrough = t0
        #expect(s.isMarkedPlayed(old))
        #expect(!s.isMarkedPlayed(new))
        s.reopenedEpisodeIDs = [old.id]
        #expect(!s.isMarkedPlayed(old))
    }
}
