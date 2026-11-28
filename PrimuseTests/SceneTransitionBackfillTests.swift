import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 设备上找到的装载:进后台(或在后台里播放开始、停下)时补读有活儿,场景切换用 `onReady(holding: .backfill)` 把
/// 放掉的歌曲模型请了回来,装到一半进程就被挂起。现在那几处调 `startForSceneTransition()`:模型不在内存里时不请它
/// 装回来(`start()` 自己在发布时开工,等模型因别的原因装回来;没人装回来就留给后台处理任务)。
@MainActor
final class SceneTransitionBackfillTests: LibraryReleasedTwinTestCase {
    func testStartingBackfillOnASceneTransitionWhileReleasedAsksForNoLoad() async throws {
        let prefix = "scene-backfill"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let state = directory.appendingPathComponent("\(prefix)-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let backfill = MetadataBackfillService(
            library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { [Self.sourceA] }, storageDirectory: state
        )
        defer { backfill.stop() }

        let before = try await releaseForReal(library)
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        XCTAssertTrue(backfill.hasPendingWork, "a fresh queue has work to look at")
        // 场景切换那三处调的就是它(进后台时播放 / 不播放,后台里播放状态变了);连调几次也一样。
        backfill.startForSceneTransition()
        backfill.startForSceneTransition()
        try await Task.sleep(for: .milliseconds(300))
        assertNoLoadAndNoArrayRead(library, since: before, "backfill start on a scene transition while released")
        XCTAssertEqual(songModelHolds(of: library), [], "nothing asked for the song model")
        XCTAssertFalse(library.songModelHoldReasons.contains(.backfill))
        XCTAssertFalse(library.isReady, "the model stays out")
        XCTAssertFalse(backfill.isRunning, "no worker without the model")
    }
}
