import Foundation
import Testing
@testable import PrimuseKit

@Suite("Now-playing artist links")
struct ArtistLinkResolutionPolicyTests {
    @Test("Names the library already knows are kept as they are")
    func knownNamesWin() {
        let library: Set<String> = ["simon & garfunkel", "周杰伦"]
        let links = ArtistLinkResolutionPolicy.linkCandidates(for: ["Simon & Garfunkel", "周杰伦"]) {
            library.contains($0.lowercased())
        }
        #expect(links == ["Simon & Garfunkel", "周杰伦"])
    }

    @Test("Unknown combined credits fall back to their pieces")
    func combinedCreditsSplit() {
        let library: Set<String> = ["jay chou", "lara", "coldplay", "beyoncé", "王菲"]
        let resolves: (String) -> Bool = { library.contains($0.lowercased()) }
        #expect(ArtistLinkResolutionPolicy.linkCandidates(for: ["Jay Chou feat. Lara"], resolves: resolves)
            == ["Jay Chou", "Lara"])
        #expect(ArtistLinkResolutionPolicy.linkCandidates(for: ["Coldplay FT. Beyoncé"], resolves: resolves)
            == ["Coldplay", "Beyoncé"])
        #expect(ArtistLinkResolutionPolicy.linkCandidates(for: ["王菲，那英"], resolves: resolves) == ["王菲"])
        #expect(ArtistLinkResolutionPolicy.linkCandidates(for: ["Nobody & Nothing"], resolves: resolves).isEmpty)
    }

    @Test("Duplicates collapse by artist identity")
    func duplicatesCollapse() {
        let links = ArtistLinkResolutionPolicy.linkCandidates(for: ["Adele", "adele", "ADELE x Adele"]) { _ in true }
        #expect(links == ["Adele", "ADELE x Adele"])
        #expect(ArtistLinkResolutionPolicy.fallbackPieces(of: "A x B × C, D & E") == ["A", "B", "C", "D", "E"])
    }
}

@Suite("Placeholder artist credits")
struct PlaceholderArtistPolicyTests {
    @Test("Compilation and unknown credits are not an artist")
    func placeholdersAreRecognised() {
        for name in [
            "群星", " 羣星 ", "华语群星", "欧美群星", "Various Artists", "VARIOUS  ARTISTS", "V.A.", "va",
            "ＶＡＲＩＯＵＳ ＡＲＴＩＳＴＳ", "Unknown Artist", "未知艺术家", "多位藝人", "Varios Artistas", "Разные исполнители",
        ] {
            #expect(PlaceholderArtistPolicy.isPlaceholder(name), "\(name)")
        }
    }

    @Test("Real artists are kept, including names that merely contain the words")
    func realArtistsAreKept() {
        for name in ["周杰伦", "群星闪耀合唱团", "Various Cruelties", "Vanessa", "VAST", "Unknown Mortal Orchestra", "王菲", "", "  "] {
            #expect(!PlaceholderArtistPolicy.isPlaceholder(name), "\(name)")
        }
    }
}
