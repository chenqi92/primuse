import Foundation
import Testing
@testable import PrimuseKit

/// 长的 fast-start m4a/m4b: moov 超出首段时按顶层 atom 的长度声明补读。
struct ISOBaseMediaHeadExpansionTests {
    typealias Policy = RemoteMetadataReadPolicy

    private func atom(_ type: String, size: Int) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(size).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(type.utf8))
        data.append(Data(repeating: 0, count: max(0, size - 8)))
        return data
    }

    private func largeAtomHeader(_ type: String, size: UInt64) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(type.utf8))
        withUnsafeBytes(of: size.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// 40 分钟 AAC 单集的实测排法: ftyp 28 字节, moov 414 440 字节, 之后是 free 与 mdat。
    private var fortyMinuteEpisode: Data {
        atom("ftyp", size: 28) + atom("moov", size: 414_440) + atom("free", size: 8) + atom("mdat", size: 64)
    }

    @Test func truncatedFastStartMoovExpandsToItsDeclaredEnd() {
        let head = fortyMinuteEpisode.prefix(256 * 1024)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 14_939_770, currentData: head) == 414_468)
    }

    @Test func completeMoovInHeadNeedsNoMore() {
        let shortEpisode = atom("ftyp", size: 28) + atom("moov", size: 104_296) + atom("mdat", size: 64)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 3_735_546, currentData: shortEpisode) == nil)
        let expanded = fortyMinuteEpisode.prefix(414_468)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 14_939_770, currentData: expanded) == nil)
    }

    @Test func trailingMoovIsLeftToTheTailRead() {
        let trailing = atom("ftyp", size: 28) + atom("free", size: 8) + atom("mdat", size: 1_000)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 9_000_000, currentData: trailing.prefix(512)) == nil)
    }

    @Test func paddingBeforeMoovIsSteppedOver() {
        let padded = atom("ftyp", size: 28) + atom("free", size: 300_000) + atom("moov", size: 50_000)
        let head = padded.prefix(256 * 1024)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 9_000_000, currentData: head) == 300_028 + 16)
        let next = padded.prefix(300_028 + 16)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 9_000_000, currentData: next) == 350_028)
    }

    @Test func sixtyFourBitMoovSizeIsHonoured() {
        let head = atom("ftyp", size: 28) + largeAtomHeader("moov", size: 600_000) + Data(repeating: 0, count: 1_000)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 50_000_000, currentData: head) == 600_028)
    }

    @Test func moovBeyondTheCeilingIsNotChased() {
        let head = atom("ftyp", size: 28) + largeAtomHeader("moov", size: 40_000_000)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 900_000_000, currentData: head) == nil)
    }

    @Test func neverReadsPastTheFileEnd() {
        // 声明比文件还长的 moov 是坏文件, 不去追。
        let head = atom("ftyp", size: 28) + Data(atom("moov", size: 500_000).prefix(1_000))
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 400_000, currentData: head) == nil)
    }

    @Test func nonISODataIsIgnored() {
        let id3 = Data("ID3".utf8) + Data(repeating: 0, count: 1_000)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 5_000_000, currentData: id3) == nil)
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 5_000_000, currentData: Data()) == nil)
    }

    @Test func worksOnDataSlicesWithNonZeroStartIndex() {
        let backing = Data(repeating: 0xAA, count: 7) + fortyMinuteEpisode.prefix(256 * 1024)
        let slice = backing[7...]
        #expect(Policy.expandedISOBaseMediaReadSize(fileSize: 14_939_770, currentData: slice) == 414_468)
    }
}
