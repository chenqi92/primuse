import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 云盘托管的本机源登记表(设备本地,存在 UserDefaults):记得住、去得掉;源管理器同步源列表时只动它认得的源。
@MainActor
final class CloudBackedLocalSourceRegistryTests: XCTestCase {
    func testRegistryPersistsAndUnregisters() throws {
        let suiteName = "primuse.test.cloudLocalRegistry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = CloudBackedLocalSourceRegistry(defaults: defaults)
        XCTAssertTrue(registry.sourceIDs.isEmpty)
        registry.register(sourceID: "src-a")
        registry.register(sourceID: "src-b")
        XCTAssertTrue(registry.contains("src-a"))
        XCTAssertEqual(registry.sourceIDs, ["src-a", "src-b"])

        let reloaded = CloudBackedLocalSourceRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.sourceIDs, ["src-a", "src-b"])
        reloaded.unregister(sourceID: "src-a")
        XCTAssertFalse(reloaded.contains("src-a"))
        XCTAssertEqual(CloudBackedLocalSourceRegistry(defaults: defaults).sourceIDs, ["src-b"])
    }

    /// 测试里另建的源管理器只认得自己那几个源:看到源列表时不能把别的源的登记清掉(那是 App 自己的登记);
    /// 它认得的、已经删掉的或不是本机文件夹的源才去掉登记,路径在 iCloud 云盘里的本机源记上。
    func testSourceManagerOnlyUnregistersSourcesItKnows() {
        let registry = CloudBackedLocalSourceRegistry.shared
        let foreign = "test-foreign-\(UUID().uuidString)"
        let deleted = MusicSource(
            id: "test-deleted-\(UUID().uuidString)", name: "Gone", type: .local,
            basePath: "/Users/listener/Library/Mobile Documents/com~apple~CloudDocs/Old", isDeleted: true
        )
        let remote = MusicSource(id: "test-remote-\(UUID().uuidString)", name: "NAS", type: .webdav)
        let cloud = MusicSource(
            id: "test-cloud-\(UUID().uuidString)", name: "iCloud", type: .local,
            basePath: "/Users/listener/Library/Mobile Documents/com~apple~CloudDocs/Music"
        )
        for id in [foreign, deleted.id, remote.id] { registry.register(sourceID: id) }
        defer { for id in [foreign, deleted.id, remote.id, cloud.id] { registry.unregister(sourceID: id) } }

        let manager = SourceManager(sourcesProvider: { [] })
        manager.probeCloudBackedLocalSources([deleted, remote, cloud])
        XCTAssertTrue(registry.contains(foreign), "a source this manager does not know keeps its registration")
        XCTAssertFalse(registry.contains(deleted.id))
        XCTAssertFalse(registry.contains(remote.id))
        XCTAssertTrue(registry.contains(cloud.id))
        XCTAssertTrue(manager.isCloudBackedLocalSourceID(cloud.id))
        XCTAssertFalse(manager.isCloudBackedLocalSourceID(remote.id))
    }
}
