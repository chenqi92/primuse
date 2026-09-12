import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 整份替换 `library-cache.json` 时的写入栅栏回归。
///
/// Apple TV 安装整库快照是用事务整份替换这个文件的, 而那次写入不走
/// `MusicLibrary` 自己的写入链。安装期间本类还会让出主 actor (准备阶段在后台
/// 算), 播放记账与生命周期落盘都能在那段时间里出发自己的后台写入 —— 一笔
/// 早于事务出发、晚于事务落盘的写入会把刚装好的整库覆盖回安装前的内容。
///
/// 这些用例不靠 sleep 排序: 每一步都用真实的完成信号 (屏障落盘的返回、
/// 栅栏的取得与交还) 作为栅栏, 断言的是文件里最终的字节。
@MainActor
final class LibrarySnapshotWriteFenceTests: XCTestCase {
    private static func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSnapshotFenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let sourceID = "source-a"

    private static func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Title \(id)",
            albumTitle: "Album",
            artistName: "Artist",
            duration: 180,
            fileFormat: .flac,
            filePath: "/Music/\(id).flac",
            sourceID: sourceID
        )
    }

    private func snapshotURL(in directory: URL) -> URL {
        directory.appendingPathComponent("library-cache.json")
    }

    /// 模拟安装事务: 整份替换快照文件, 完全不经过 MusicLibrary 的写入链。
    private func installExternalSnapshot(into directory: URL, marker: String) throws {
        let payload = ["externalInstallMarker": marker]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: snapshotURL(in: directory), options: .atomic)
    }

    private func externalMarker(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: snapshotURL(in: directory)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["externalInstallMarker"] as? String
    }

    /// 在途的后台写入必须在栅栏取得时就已经落完 —— 这正是"早于事务出发、
    /// 晚于事务落盘"的那一笔。取得栅栏之后装上外部快照, 文件里必须是外部
    /// 内容, 而不是被那笔写入盖回去的库内容。
    func testInFlightWriteCannotLandAfterTheExternalInstall() async throws {
        let directory = try Self.makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([Self.makeSong(id: "a")])
        // 不等它落盘: 让这笔写入停在半途, 栅栏负责把它等干净。
        library.persistNow()

        await library.beginExternalSnapshotWrite()
        XCTAssertTrue(library.isExternalSnapshotWriteOwned)
        try installExternalSnapshot(into: directory, marker: "installed")
        library.endExternalSnapshotWrite()

        XCTAssertEqual(externalMarker(in: directory), "installed")
    }

    /// 栅栏期间发出的防抖写入不能落盘, 但也不能被丢掉: 交还之后必须补上,
    /// 而且补的是交还时刻的内存状态。
    func testDebouncedWriteRequestedDuringTheFenceIsDeferredThenHonoured() async throws {
        let directory = try Self.makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([Self.makeSong(id: "a")])
        _ = await library.persistNowAndWait()

        await library.beginExternalSnapshotWrite()
        try installExternalSnapshot(into: directory, marker: "installed")
        // 安装期间的本地改动: 只在内存里, 写入被推迟。
        // 必须用增量形式 —— `addSongs` 默认会把这个源里没带上的歌当作已消失
        // 而剪掉, 那是整源重扫的语义, 不是本地新增一首的语义。
        library.addSongs(
            [Self.makeSong(id: "b")],
            affectedSourceIDs: [Self.sourceID],
            pruneMissingSongs: false
        )
        XCTAssertEqual(externalMarker(in: directory), "installed",
                       "栅栏期间库的写入不能落到刚装好的文件上")

        library.endExternalSnapshotWrite()
        // 交还之后补写, 用屏障落盘把它等干净, 不用 sleep 排序。
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("交还之后的落盘应当成功")
        }
        XCTAssertNil(externalMarker(in: directory),
                     "交还之后库应当把自己的状态写回去")
        XCTAssertNotNil(library.song(id: "b"), "安装期间的本地改动不能丢")
        XCTAssertNotNil(library.song(id: "a"))
    }

    /// 屏障语义的写入方 (生命周期落盘) 在栅栏期间必须被挡住并等待, 而不是
    /// 空写成功 —— 空写成功会让调用方提交一个磁盘上并不存在的状态。
    func testBarrierWriterBlocksUntilTheFenceIsReleased() async throws {
        let directory = try Self.makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([Self.makeSong(id: "a")])
        _ = await library.persistNowAndWait()

        await library.beginExternalSnapshotWrite()
        try installExternalSnapshot(into: directory, marker: "installed")

        // 生产时序里, 安装之后资料库会重载并把本地改动合并回来, 内存状态因此
        // 发生变化, 交还栅栏之后那次屏障落盘写的就是这份合并结果。这里用一次
        // 真实的本地新增代表那个变化。没有新改动时屏障落盘本来就不该写盘 ——
        // 那正是安装期间想要的行为, 不能拿"用旧内存覆盖刚装好的文件"当契约。
        library.addSongs(
            [Self.makeSong(id: "b")],
            affectedSourceIDs: [Self.sourceID],
            pruneMissingSongs: false
        )

        let blocked = Task { @MainActor in await library.persistNowAndWait() }
        // 真正的同步点: 等到那个调用已经登记为"被挡住", 再断言它没有落盘。
        // 用的是库自己的状态, 不是 sleep。
        var spins = 0
        while library.blockedSnapshotWriterCount == 0 {
            spins += 1
            XCTAssertLessThan(spins, 10_000, "屏障写入没有登记为被挡住")
            await Task.yield()
        }
        XCTAssertEqual(library.blockedSnapshotWriterCount, 1)
        XCTAssertEqual(externalMarker(in: directory), "installed",
                       "被挡住的屏障写入不能在栅栏期间落盘")

        library.endExternalSnapshotWrite()
        guard case .success = await blocked.value else {
            return XCTFail("放行之后被挡住的落盘应当成功")
        }
        XCTAssertNil(externalMarker(in: directory),
                     "放行之后那笔屏障写入才把库状态写回去")
        XCTAssertNotNil(library.song(id: "a"), "导入前就有的歌必须还在")
        XCTAssertNotNil(library.song(id: "b"), "安装期间的本地改动必须还在")
    }

    /// 安装失败时栅栏同样要交还, 后续写入必须恢复正常。
    func testFenceIsReleasedWhenTheInstallFails() async throws {
        let directory = try Self.makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([Self.makeSong(id: "a")])
        _ = await library.persistNowAndWait()

        await library.beginExternalSnapshotWrite()
        // 安装在写文件之前就失败了: 文件没被替换, 栅栏照样交还。
        library.endExternalSnapshotWrite()
        XCTAssertFalse(library.isExternalSnapshotWriteOwned)

        library.addSongs(
            [Self.makeSong(id: "b")],
            affectedSourceIDs: [Self.sourceID],
            pruneMissingSongs: false
        )
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("交还之后落盘应当恢复正常")
        }
        XCTAssertNotNil(library.song(id: "a"))
        XCTAssertNotNil(library.song(id: "b"))
    }

    /// 嵌套取得: 只有最外层交还才真正放行。
    func testNestedOwnershipReleasesOnlyOnTheOutermostRelease() async throws {
        let directory = try Self.makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([Self.makeSong(id: "a")])
        _ = await library.persistNowAndWait()

        await library.beginExternalSnapshotWrite()
        await library.beginExternalSnapshotWrite()
        try installExternalSnapshot(into: directory, marker: "installed")

        library.endExternalSnapshotWrite()
        XCTAssertTrue(library.isExternalSnapshotWriteOwned, "内层交还不应当放行")
        library.addSongs(
            [Self.makeSong(id: "b")],
            affectedSourceIDs: [Self.sourceID],
            pruneMissingSongs: false
        )
        XCTAssertEqual(externalMarker(in: directory), "installed")

        library.endExternalSnapshotWrite()
        XCTAssertFalse(library.isExternalSnapshotWriteOwned)
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("最外层交还之后落盘应当成功")
        }
        XCTAssertNil(externalMarker(in: directory))
        XCTAssertNotNil(library.song(id: "a"))
        XCTAssertNotNil(library.song(id: "b"))
    }
}
