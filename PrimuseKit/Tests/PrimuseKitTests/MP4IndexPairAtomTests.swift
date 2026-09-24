import Foundation
import Testing
@testable import PrimuseKit

@Suite("MP4 track and disc items")
struct MP4IndexPairAtomTests {
    @Test("A trkn payload gives number and total")
    func trackPayload() {
        let value = MP4IndexPairAtom.decode(Data([0, 0, 0, 2, 0, 6, 0, 0]))
        #expect(value == MP4IndexPairAtom.Value(number: 2, total: 6))
    }

    @Test("A disk payload is six bytes")
    func discPayload() {
        let value = MP4IndexPairAtom.decode(Data([0, 0, 0, 1, 0, 2]))
        #expect(value == MP4IndexPairAtom.Value(number: 1, total: 2))
    }

    @Test("Numbers above 255 use both bytes")
    func wideNumbers() {
        #expect(MP4IndexPairAtom.decode(Data([0, 0, 1, 44, 0, 0]))?.number == 300)
    }

    @Test("Zero means unknown, and a short payload is not a pair")
    func zeroAndShort() {
        #expect(MP4IndexPairAtom.decode(Data([0, 0, 0, 0, 0, 6, 0, 0])) == MP4IndexPairAtom.Value(number: nil, total: 6))
        #expect(MP4IndexPairAtom.decode(Data([0, 0, 0])) == nil)
        #expect(MP4IndexPairAtom.decode(Data([0, 0, 0, 5])) == MP4IndexPairAtom.Value(number: 5, total: nil))
    }
}
