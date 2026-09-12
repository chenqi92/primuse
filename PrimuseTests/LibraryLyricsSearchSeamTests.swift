import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 歌词缓存通知的记录器。转义闭包不能捕获可变局部变量, 所以用一个主线程
/// 隔离的引用类型收集顺序。`storedGeneration` 是回调发生那一刻偏好存储里的
/// 代际值 —— 代际分配与入链之间一旦插进异步跳转, 它就会跑在 `generation`
/// 前面。
@MainActor
private final class LyricsSearchOrderRecorder {
    struct Event {
        let songID: String
        let fallbackText: String?
        let generation: Int
        let storedGeneration: Int
    }

    private(set) var events: [Event] = []

    func record(songID: String, fallbackText: String?, generation: Int, storedGeneration: Int) {
        events.append(
            Event(
                songID: songID,
                fallbackText: fallbackText,
                generation: generation,
                storedGeneration: storedGeneration
            )
        )
    }
}

/// `.primuseLyricsDidCache` 观察者的排序不变量。
///
/// 代际分配 (`LibrarySearchIndex.persistLibraryChangePending`) 必须和入链
/// (`enqueueLyricsSearchIndexRefresh`) 发生在同一个主线程轮次里。中间只要多
/// 一次异步跳转, 后分配的代际就可能先入链, 让
/// `markIncrementalPreparationCompleted` 的连续性检查永久失败 —— 增量索引再也
/// 无法结账, 每次启动都要重跑全库准备。
@MainActor
final class LibraryLyricsSearchSeamTests: XCTestCase {
    private static let generationKey = "primuse.librarySearchIndex.preparationGeneration.v1"

    private func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLyricsSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForEvents(
        _ recorder: LyricsSearchOrderRecorder,
        count: Int,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while recorder.events.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testLyricsCacheNotificationsEnqueueGenerationsInAllocationOrder() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "primuse.tests.lyricsSeam.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = LyricsSearchOrderRecorder()
        let library = MusicLibrary(
            storageDirectory: directory,
            searchIndexDefaults: defaults,
            lyricsSearchIndexRefresh: { songID, fallbackText, generation in
                recorder.record(
                    songID: songID,
                    fallbackText: fallbackText,
                    generation: generation,
                    storedGeneration: defaults.integer(forKey: Self.generationKey)
                )
            }
        )

        let postedCount = 5
        for index in 0..<postedCount {
            NotificationCenter.default.post(
                name: .primuseLyricsDidCache,
                object: nil,
                userInfo: ["songID": "song-\(index)", "lyricsText": "lyrics-\(index)"]
            )
        }
        await waitForEvents(recorder, count: postedCount)

        XCTAssertEqual(recorder.events.count, postedCount)
        // 严格递增、无跳号、无乱序。
        XCTAssertEqual(recorder.events.map(\.generation), Array(1...postedCount))
        XCTAssertEqual(
            recorder.events.map(\.songID),
            (0..<postedCount).map { "song-\($0)" }
        )
        XCTAssertEqual(
            recorder.events.compactMap(\.fallbackText),
            (0..<postedCount).map { "lyrics-\($0)" }
        )
        // 判别性断言: 分配与入链同轮次时, 回调看到的持久化代际就是自己那一代。
        // 中间插一次 Task hop 会让所有回调都看到最后一代。
        for event in recorder.events {
            XCTAssertEqual(event.storedGeneration, event.generation)
        }
        XCTAssertEqual(defaults.integer(forKey: Self.generationKey), postedCount)
        XCTAssertTrue(
            LibrarySearchIndex.hasPendingPreparation(defaults: defaults),
            "A cached lyrics batch must leave the search index marked pending"
        )
        withExtendedLifetime(library) {}
    }

    func testPostsWithoutASongIDAllocateNoGeneration() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "primuse.tests.lyricsSeam.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = LyricsSearchOrderRecorder()
        let library = MusicLibrary(
            storageDirectory: directory,
            searchIndexDefaults: defaults,
            lyricsSearchIndexRefresh: { songID, fallbackText, generation in
                recorder.record(
                    songID: songID,
                    fallbackText: fallbackText,
                    generation: generation,
                    storedGeneration: defaults.integer(forKey: Self.generationKey)
                )
            }
        )

        NotificationCenter.default.post(
            name: .primuseLyricsDidCache,
            object: nil,
            userInfo: ["lyricsText": "orphan"]
        )
        NotificationCenter.default.post(
            name: .primuseLyricsDidCache,
            object: nil,
            userInfo: ["songID": "song-0", "lyricsText": "lyrics-0"]
        )
        await waitForEvents(recorder, count: 1)

        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.events.first?.songID, "song-0")
        // 没有 songID 的投递直接返回, 不得消耗一个代际。
        XCTAssertEqual(recorder.events.first?.generation, 1)
        XCTAssertEqual(defaults.integer(forKey: Self.generationKey), 1)
        withExtendedLifetime(library) {}
    }
}
