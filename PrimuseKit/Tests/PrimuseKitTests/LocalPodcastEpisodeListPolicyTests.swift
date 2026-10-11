import Foundation
import Testing
@testable import PrimuseKit

@Suite("Local podcast episode list")
struct LocalPodcastEpisodeListPolicyTests {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 章节顺序(曲目号、文件名)就是 ep1…ep4;日期故意和它不一致。
    private func items(finished: Set<String> = [], positions: [String: TimeInterval] = [:]) -> [SpokenWordBookItem] {
        let dates: [String: TimeInterval?] = ["ep1": 0, "ep2": 3, "ep3": 1, "ep4": 2]
        return ["ep1", "ep2", "ep3", "ep4"].map { id in
            SpokenWordBookItem(
                id: id,
                title: id,
                duration: 1_800,
                position: positions[id],
                finishedAt: finished.contains(id) ? t0 : nil,
                addedAt: dates[id]!.map { t0.addingTimeInterval($0 * day) }
            )
        }
    }

    private func ids(_ items: [SpokenWordBookItem]) -> [String] { items.map(\.id) }

    @Test func newestFirstPutsTheLatestFileOnTop() {
        let ordered = LocalPodcastEpisodeListPolicy.ordered(items(), settings: .init(order: .newestFirst))
        #expect(ids(ordered) == ["ep2", "ep4", "ep3", "ep1"])
    }

    @Test func oldestFirstAndFileOrder() {
        #expect(ids(LocalPodcastEpisodeListPolicy.ordered(items(), settings: .init(order: .oldestFirst)))
            == ["ep1", "ep3", "ep4", "ep2"])
        #expect(ids(LocalPodcastEpisodeListPolicy.ordered(items(), settings: .init(order: .fileOrder)))
            == ["ep1", "ep2", "ep3", "ep4"])
    }

    @Test func sameDateFallsBackToFileOrderAndUndatedGoLast() {
        let list = ["a", "b", "c", "d"].map { id in
            SpokenWordBookItem(id: id, title: id, duration: 60, addedAt: id == "c" ? nil : t0)
        }
        #expect(ids(LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .newestFirst)))
            == ["d", "b", "a", "c"])
        #expect(ids(LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .oldestFirst)))
            == ["a", "b", "d", "c"])
    }

    @Test func customOrderKeepsTheDraggedOrderAndPutsNewEpisodesOnTop() {
        var all = items()
        let settings = LocalPodcastShowSettings(order: .custom, customOrder: ["ep3", "gone", "ep1", "ep3"])
        // ep2、ep4 不在拖过的顺序里:新加进来的,按日期新的在上排在最前面。
        #expect(ids(LocalPodcastEpisodeListPolicy.ordered(all, settings: settings)) == ["ep2", "ep4", "ep3", "ep1"])
        all.append(SpokenWordBookItem(id: "ep5", title: "ep5", duration: 60, addedAt: t0.addingTimeInterval(9 * day)))
        #expect(ids(LocalPodcastEpisodeListPolicy.ordered(all, settings: settings)).first == "ep5")
    }

    @Test func filterSplitsPlayedFromUnplayed() {
        let list = items(finished: ["ep1"], positions: ["ep2": 60])
        #expect(ids(list.filter { LocalPodcastEpisodeFilter.unplayed.includes($0) }) == ["ep2", "ep3", "ep4"])
        #expect(ids(list.filter { LocalPodcastEpisodeFilter.played.includes($0) }) == ["ep1"])
        #expect(list.filter { LocalPodcastEpisodeFilter.all.includes($0) }.count == 4)
    }

    @Test func continuationRunsTowardNewerAndSkipsFinished() {
        let list = items(finished: ["ep4"])
        let newest = LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .newestFirst))
        // 列表 ep2 ep4 ep3 ep1;点 ep1 之后往新的方向:ep3,跳过听完的 ep4,再 ep2。
        #expect(ids(LocalPodcastEpisodeListPolicy.continuation(from: "ep1", in: newest, order: .newestFirst))
            == ["ep1", "ep3", "ep2"])
        // 点的这一集即使听完了也照放。
        #expect(ids(LocalPodcastEpisodeListPolicy.continuation(from: "ep4", in: newest, order: .newestFirst))
            == ["ep4", "ep2"])
        let files = LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .fileOrder))
        #expect(ids(LocalPodcastEpisodeListPolicy.continuation(from: "ep2", in: files, order: .fileOrder))
            == ["ep2", "ep3"])
        #expect(LocalPodcastEpisodeListPolicy.continuation(from: "missing", in: files, order: .fileOrder).isEmpty)
    }

    @Test func startItemPrefersResumeThenFirstUnfinishedInList() {
        let list = items(finished: ["ep2"])
        let newest = LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .newestFirst))
        #expect(LocalPodcastEpisodeListPolicy.startItemID(in: newest, resumeItemID: "ep3", canContinue: true) == "ep3")
        #expect(LocalPodcastEpisodeListPolicy.startItemID(in: newest, resumeItemID: "ep3", canContinue: false) == "ep4")
        let allDone = items(finished: ["ep1", "ep2", "ep3", "ep4"])
        #expect(LocalPodcastEpisodeListPolicy.startItemID(in: allDone, resumeItemID: nil, canContinue: false) == "ep1")
        #expect(LocalPodcastEpisodeListPolicy.startItemID(in: [], resumeItemID: nil, canContinue: false) == nil)
    }

    @Test func earlierEpisodesFollowTheListeningDirection() {
        let list = items(finished: ["ep3"])
        let newest = LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .newestFirst))
        // 收听先后 ep1 ep3 ep4 ep2:ep4 之前没听完的只有 ep1。
        #expect(LocalPodcastEpisodeListPolicy.earlierUnfinishedIDs(than: "ep4", in: newest, order: .newestFirst) == ["ep1"])
        let files = LocalPodcastEpisodeListPolicy.ordered(list, settings: .init(order: .fileOrder))
        #expect(LocalPodcastEpisodeListPolicy.earlierUnfinishedIDs(than: "ep4", in: files, order: .fileOrder) == ["ep1", "ep2"])
    }

    @Test func settingsRoundTripAndTolerateUnknownValues() throws {
        let settings = LocalPodcastShowSettings(order: .custom, filter: .played, customOrder: ["a", "b"])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(LocalPodcastShowSettings.self, from: data) == settings)
        let future = Data(#"{"order":"byDuration","filter":"downloaded","customOrder":["x"]}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalPodcastShowSettings.self, from: future)
        #expect(decoded == LocalPodcastShowSettings(order: .newestFirst, filter: .all, customOrder: ["x"]))
        #expect(try JSONDecoder().decode(LocalPodcastShowSettings.self, from: Data("{}".utf8)) == .default)
    }

    @Test func addedDateTakesTheEarlierOfLibraryAndFileDates() {
        let scanned = t0
        let file = t0.addingTimeInterval(-30 * day)
        #expect(SpokenWordBookItem.addedDate(dateAdded: scanned, fileModified: file) == file)
        // 后来改过标签的文件:修改时间更新,仍按曲库第一次见到它的时间。
        #expect(SpokenWordBookItem.addedDate(dateAdded: scanned, fileModified: t0.addingTimeInterval(day)) == scanned)
        #expect(SpokenWordBookItem.addedDate(dateAdded: scanned, fileModified: nil) == scanned)
        // 服务器没报修改时间时给的 1970 不算。
        #expect(SpokenWordBookItem.addedDate(dateAdded: scanned, fileModified: Date(timeIntervalSince1970: 0)) == scanned)
    }
}
