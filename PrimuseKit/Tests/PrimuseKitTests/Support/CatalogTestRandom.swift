// 两个包共用这一份(只此一份):PrimuseKitTests 直接编它,Release 规模门 `PrimuseKit/ScaleGate`
// 经 `Tests/ScaleGateTests/Shared/` 下的相对符号链接编它。

/// 可复现的随机数(SplitMix64)。失败时打印种子,用同一种子重放。
struct CatalogTestRandom {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound) &+ 1
        return range.lowerBound + Int(width == 0 ? next() : next() % width)
    }

    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }

    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }

    mutating func maybe<T>(_ percent: Int, _ make: (inout CatalogTestRandom) -> T) -> T? {
        chance(percent) ? make(&self) : nil
    }
}
