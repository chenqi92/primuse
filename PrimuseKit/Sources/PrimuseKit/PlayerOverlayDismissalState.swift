public struct PlayerOverlayDismissalState: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var isDismissing: Bool

    public init(generation: UInt64 = 0, isDismissing: Bool = false) {
        self.generation = generation
        self.isDismissing = isDismissing
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        isDismissing = true
        return generation
    }

    public mutating func cancelForSystemInterruption() {
        guard isDismissing else { return }
        generation &+= 1
        isDismissing = false
    }

    @discardableResult
    public mutating func complete(generation candidate: UInt64) -> Bool {
        guard isDismissing, generation == candidate else { return false }
        isDismissing = false
        return true
    }
}
