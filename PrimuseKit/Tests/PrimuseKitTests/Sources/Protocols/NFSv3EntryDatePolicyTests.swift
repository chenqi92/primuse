import Foundation
import Testing
@testable import PrimuseKit

/// NFSv3 的修改时间进了歌曲的文件版本,换掉 NFSKit 之后必须逐位得到同样的值。
@Suite("NFSv3 entry date")
struct NFSv3EntryDatePolicyTests {
    /// NFSKit `Date.init(_ timespec:)` 原样抄写。
    private static func nfsKitDate(seconds: Int, nanoseconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds / 1000) / TimeInterval(1_000_000))
    }

    @Test("Matches the former NFSKit conversion bit for bit")
    func matchesNFSKit() {
        let samples: [(Int, UInt32)] = [
            (0, 0),
            (1_700_000_000, 0),
            (1_700_000_000, 123_456_789),
            (1_760_412_345, 999_999_999),
            (946_684_800, 1_000),
            (2_147_483_647, 500_000_000),
        ]
        for (seconds, nanoseconds) in samples {
            let date = NFSv3EntryDatePolicy.modifiedDate(seconds: seconds, nanoseconds: nanoseconds)
            let expected = Self.nfsKitDate(seconds: seconds, nanoseconds: Int(nanoseconds))
            #expect(date.timeIntervalSince1970.bitPattern == expected.timeIntervalSince1970.bitPattern)
        }
    }

    @Test("Sub-microsecond digits are dropped before converting")
    func truncatesToMicroseconds() {
        #expect(NFSv3EntryDatePolicy.modifiedDate(seconds: 1_700_000_000, nanoseconds: 123_456_999)
            == NFSv3EntryDatePolicy.modifiedDate(seconds: 1_700_000_000, nanoseconds: 123_456_000))
        #expect(NFSv3EntryDatePolicy.modifiedDate(seconds: 1_700_000_000, nanoseconds: 123_457_000)
            != NFSv3EntryDatePolicy.modifiedDate(seconds: 1_700_000_000, nanoseconds: 123_456_000))
    }
}
