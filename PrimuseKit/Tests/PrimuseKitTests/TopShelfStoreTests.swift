import Foundation
import Testing
@testable import PrimuseKit

struct TopShelfStoreTests {
    /// tvOS 真机只允许写共享容器里的 `Library/Caches`,写到容器根目录会静默失败,Top Shelf 就一直是空的。
    @Test func storageLivesUnderSharedContainerCaches() {
        let container = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/ABC", isDirectory: true)
        #expect(TopShelfStore.storageDirectory(inContainer: container).path
            == "/private/var/mobile/Containers/Shared/AppGroup/ABC/Library/Caches")
    }
}
