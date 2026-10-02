import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI semantic search puts the album group first when the query is after an album")
struct AISemanticAlbumGroupPolicyTests {
    private let titles = ["范特西", "Abbey Road", "21", "红豆", "The Dark Side of the Moon"]

    @Test("Songs lead by default")
    func songsLeadByDefault() {
        #expect(AISemanticAlbumGroupPolicy.groupOrder(query: "下雨天的爵士", albumTitles: titles) == [.songs, .albums])
        #expect(AISemanticAlbumGroupPolicy.groupOrder(query: "  ", albumTitles: titles) == [.songs, .albums])
        #expect(AISemanticAlbumGroupPolicy.groupOrder(query: "deep house", albumTitles: []) == [.songs, .albums])
    }

    @Test("Album words in the query bring albums first")
    func albumWords() {
        for query in ["周杰伦那张专辑", "适合开车的整张唱片", "放一張專輯", "jazz album", "a chill LP", "Ｌｏｆｉ ＥＰ",
                      "夜に聴くアルバム", "드라이브 앨범"] {
            #expect(AISemanticAlbumGroupPolicy.groupOrder(query: query, albumTitles: []) == [.albums, .songs], "\(query)")
        }
        // Words that merely contain the letters do not count.
        #expect(!AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("deep sleep", albumTitles: []))
        #expect(!AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("albumen", albumTitles: []))
    }

    @Test("A query that is, or mostly is, an album title brings albums first")
    func titleMatches() {
        #expect(AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("范特西", albumTitles: titles))
        #expect(AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("abbey road", albumTitles: titles))
        #expect(AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("ABBEY-ROAD", albumTitles: titles))
        #expect(AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("abbey roa", albumTitles: titles))
        #expect(AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("pink floyd the dark side of the moon", albumTitles: titles))
        #expect(AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("放范特西", albumTitles: titles))
    }

    @Test("Short titles that just happen to appear in a sentence do not count")
    func shortTitlesInsideSentences() {
        #expect(!AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("2021年最火的歌", albumTitles: titles))
        #expect(!AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("王菲唱的红豆和别的情歌", albumTitles: titles))
        #expect(!AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("ab", albumTitles: titles))
        #expect(!AISemanticAlbumGroupPolicy.queryLooksLikeAlbum("dark", albumTitles: titles))
    }
}
