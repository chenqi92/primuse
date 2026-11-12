import Foundation
import Testing
@testable import PrimuseKit

@Suite("Music space visibility")
struct MusicSpaceVisibilityTests {
    private let order = [
        "favorites", "songs", "albums", "artists", "genres", "folders", "releaseDate", "playlists",
        "radio", "spokenWord", "podcasts", "ambient", "recommendations", "statistics",
    ]

    @Test("Turning music off keeps only radio, spoken word, podcasts and ambient, in order")
    func sections() {
        #expect(MusicSpaceVisibility.visibleSections(order, showsMusic: true) { $0 } == order)
        #expect(
            MusicSpaceVisibility.visibleSections(order, showsMusic: false) { $0 }
                == ["radio", "spokenWord", "podcasts", "ambient"]
        )
        // 新版本加的分类认不出时按音乐算,跟着开关收起。
        #expect(MusicSpaceVisibility.isMusicSection(named: "somethingNew"))
        #expect(!MusicSpaceVisibility.isMusicSection(named: "podcasts"))
        #expect(MusicSpaceVisibility.visibleSections([String](), showsMusic: false) { $0 }.isEmpty)
    }

    @Test("Search keeps radio, books and ambient when music is off")
    func searchResults() {
        let hidden = MusicSpaceVisibility.hiddenResults([.radio], showsMusic: false)
        #expect(hidden.contains(.metadata))
        #expect(hidden.contains(.albums))
        #expect(hidden.contains(.appleMusic))
        #expect(hidden.contains(.intelligent))
        // 用户自己关掉的照旧算在内,没关的电台以外几类留着。
        #expect(hidden.contains(.radio))
        #expect(!hidden.contains(.spokenWord))
        #expect(!hidden.contains(.ambient))
        #expect(MusicSpaceVisibility.hiddenResults([.lyrics], showsMusic: true) == [.lyrics])
    }

    @Test("Only the music chip follows the switch")
    func chips() {
        #expect(!MusicSpaceVisibility.isSpaceShown(.music, showsMusic: false))
        #expect(MusicSpaceVisibility.isSpaceShown(.music, showsMusic: true))
        for space in ListeningSpace.allCases where space != .music {
            #expect(MusicSpaceVisibility.isSpaceShown(space, showsMusic: false))
        }
    }

    @Test("Home is always a tab while music is off")
    func homeTab() {
        #expect(MusicSpaceVisibility.showsHomeTab(userChoice: false, showsMusic: false))
        #expect(MusicSpaceVisibility.showsHomeTab(userChoice: true, showsMusic: false))
        #expect(!MusicSpaceVisibility.showsHomeTab(userChoice: false, showsMusic: true))
        #expect(MusicSpaceVisibility.showsHomeTab(userChoice: true, showsMusic: true))
    }

    @Test("Reordering the listed rows leaves unlisted ones in place")
    func reordering() {
        let full = ["songs", "albums", "radio", "artists", "spokenWord", "podcasts"]
        let listed = ["radio", "spokenWord", "podcasts"]
        // 把「播客」拖到最前:只在三类占的位置之间换,音乐的分类原地不动。
        #expect(
            MusicSpaceVisibility.reordering(full, listed: listed, fromOffsets: IndexSet(integer: 2), toOffset: 0)
                == ["songs", "albums", "podcasts", "artists", "radio", "spokenWord"]
        )
        // 往下拖到末尾。
        #expect(
            MusicSpaceVisibility.reordering(full, listed: listed, fromOffsets: IndexSet(integer: 0), toOffset: 3)
                == ["songs", "albums", "spokenWord", "artists", "podcasts", "radio"]
        )
        // 越界的下标不动。
        #expect(MusicSpaceVisibility.reordering(full, listed: listed, fromOffsets: IndexSet(integer: 7), toOffset: 0) == full)
        // 全列出来时就是普通的拖动。
        #expect(
            MusicSpaceVisibility.reordering(["a", "b", "c"], listed: ["a", "b", "c"], fromOffsets: IndexSet(integer: 0), toOffset: 2)
                == ["b", "a", "c"]
        )
    }
}
