import Foundation
import Testing
@testable import PrimuseKit

@Suite("Radio playlist text decoding")
struct RadioPlaylistTextTests {
    @Test("Plain UTF-8 decodes unchanged")
    func utf8() {
        let text = "#EXTM3U\n#EXTINF:-1,华语电台\nhttps://e.test/1"
        #expect(RadioPlaylistText.decode(Data(text.utf8)) == text)
    }

    @Test("A UTF-8 BOM is stripped instead of becoming a stray character")
    func utf8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("#EXTM3U".utf8))
        #expect(RadioPlaylistText.decode(data) == "#EXTM3U")
    }

    @Test("UTF-16 with a BOM decodes and loses the BOM")
    func utf16() {
        let text = "#EXTINF:-1,澳洲中文广播电台"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            var data = Data(encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
            data.append(text.data(using: encoding)!)
            #expect(RadioPlaylistText.decode(data) == text)
        }
    }

    @Test("Empty data has no text")
    func empty() {
        #expect(RadioPlaylistText.decode(Data()) == nil)
    }

    @Test("Arbitrary bytes still yield something rather than nothing")
    func fallback() {
        // 0xB5 0xE7 是「电」的 GBK 编码，不是合法 UTF-8。
        let data = Data([0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55, 0x0A, 0xB5, 0xE7])
        let decoded = RadioPlaylistText.decode(data)
        #expect(decoded?.hasPrefix("#EXTM3U") == true)
    }
}
