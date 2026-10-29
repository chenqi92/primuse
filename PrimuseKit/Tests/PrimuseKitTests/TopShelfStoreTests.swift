import Foundation
import Testing
@testable import PrimuseKit

struct TopShelfStoreTests {
    @Test func sectionsFollowListeningRecencyAndKeepTiesStable() {
        let sections = ["books", "podcasts", "recent", "radio", "albums"].map {
            TopShelfSection(id: $0, title: $0, items: [])
        }
        let dates = ["books": Date(timeIntervalSince1970: 100),
                     "podcasts": Date(timeIntervalSince1970: 300),
                     "radio": Date(timeIntervalSince1970: 200)]
        #expect(TopShelfSectionOrder.sorted(sections, lastPlayedAt: dates).map(\.id)
            == ["podcasts", "radio", "books", "recent", "albums"])
        #expect(TopShelfSectionOrder.sorted(sections, lastPlayedAt: dates, activeSectionID: "recent").map(\.id)
            == ["recent", "podcasts", "radio", "books", "albums"])
        #expect(TopShelfSectionOrder.sorted(sections, lastPlayedAt: [:], activeSectionID: "missing").map(\.id)
            == sections.map(\.id))
    }

    @Test func oldPayloadAndBookProgressRemainCompatible() throws {
        let old = Data(#"{"id":"song","title":"Song","subtitle":"Artist","playURL":"primuse://play?song=song"}"#.utf8)
        let decoded = try JSONDecoder().decode(TopShelfItem.self, from: old)
        #expect(decoded.playbackProgress == nil)
        let book = TopShelfItem(id: "book:1", title: "Book", subtitle: "Author", playURL: "primuse://book?id=1", playbackProgress: 0.38)
        #expect(try JSONDecoder().decode(TopShelfItem.self, from: JSONEncoder().encode(book)) == book)
        #expect(TopShelfItem(id: "b", title: "", subtitle: "", playURL: "", playbackProgress: 2).playbackProgress == 1)
        #expect(TopShelfItem(id: "b", title: "", subtitle: "", playURL: "", playbackProgress: .nan).playbackProgress == nil)
    }

    /// tvOS 真机只允许写共享容器里的 `Library/Caches`,写到容器根目录会静默失败,Top Shelf 就一直是空的。
    @Test func storageLivesUnderSharedContainerCaches() {
        let container = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/ABC", isDirectory: true)
        #expect(TopShelfStore.storageDirectory(inContainer: container).path
            == "/private/var/mobile/Containers/Shared/AppGroup/ABC/Library/Caches")
    }
}
