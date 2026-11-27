import Foundation

public extension BinaryFloatingPoint {
    /// Converts a floating-point value to `Int` without allowing malformed
    /// metadata (`NaN`, infinity, or an out-of-range finite value) to trap.
    /// Callers can choose a domain-appropriate fallback; durations normally
    /// use zero so an invalid value is treated as unknown.
    func finiteInt(or fallback: Int = 0) -> Int {
        let value = Double(self)
        guard value.isFinite,
              value >= Double(Int.min),
              value < Double(Int.max) else {
            return fallback
        }
        return Int(value)
    }

    /// Converts a floating-point value to `UInt64` without trapping on
    /// negative, non-finite, or out-of-range timeout/configuration values.
    func finiteUInt64(or fallback: UInt64 = 0) -> UInt64 {
        let value = Double(self)
        guard value.isFinite,
              value >= 0,
              value < Double(UInt64.max) else {
            return fallback
        }
        return UInt64(value)
    }
}
