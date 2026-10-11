import Foundation

/// Transfer rate over a short sliding window, fed with cumulative byte counts.
/// A progress display wants a figure that settles within a second or two and
/// still follows a transfer that slows down halfway through.
public struct WiFiTransferThroughput: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let time: Date
        public let bytes: Int64
    }

    /// Samples older than this no longer shape the rate.
    public static let window: TimeInterval = 3
    /// No rate is reported before this much time has been observed.
    public static let minimumSpan: TimeInterval = 0.5

    private var samples: [Sample] = []

    public init() {}

    /// Records the cumulative byte count at `time` and returns bytes per second
    /// over the recent window, or nil until enough time has been observed.
    public mutating func record(bytes: Int64, at time: Date = Date()) -> Double? {
        if let last = samples.last, bytes < last.bytes || time < last.time { samples.removeAll() }
        samples.append(Sample(time: time, bytes: bytes))
        let cutoff = time.addingTimeInterval(-Self.window)
        // Keep the newest sample at or before the cutoff so the span stays close to the window.
        while samples.count > 2, samples[1].time <= cutoff { samples.removeFirst() }
        guard let first = samples.first else { return nil }
        let span = time.timeIntervalSince(first.time)
        guard span >= Self.minimumSpan else { return nil }
        return Double(bytes - first.bytes) / span
    }

    /// "1.2 MB/s" for the diagnostic log; the interface formats its own localized copy.
    public static func describe(bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file) + "/s"
    }

    /// Bytes, seconds and the resulting rate of one finished file, for the diagnostic log.
    public static func summary(bytes: Int64, seconds: TimeInterval) -> String {
        let rate = Double(bytes) / max(seconds, 0.001)
        return "\(bytes) B in \(String(format: "%.1f", seconds)) s = \(describe(bytesPerSecond: rate))"
    }
}
