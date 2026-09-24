import Foundation

/// The payload of an MP4 `trkn` (track) or `disk` (disc) item.
///
/// iTunes stores these as binary, not text: two reserved bytes, the number
/// and the total as big-endian 16-bit integers, and (for `trkn`) two more
/// reserved bytes. AVFoundation hands the item's value back as those raw
/// bytes, so reading it as text finds nothing — every AAC/ALAC file lost its
/// track and disc numbers that way, and writing tags back then stored the
/// empty value over the real one.
public enum MP4IndexPairAtom {
    public struct Value: Equatable, Sendable {
        /// nil when the file leaves it at zero ("unknown").
        public var number: Int?
        public var total: Int?
    }

    public static func decode(_ data: Data) -> Value? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let number = Int(bytes[2]) << 8 | Int(bytes[3])
        let total = bytes.count >= 6 ? Int(bytes[4]) << 8 | Int(bytes[5]) : 0
        return Value(number: number > 0 ? number : nil, total: total > 0 ? total : nil)
    }
}
