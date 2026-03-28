import Foundation

public struct LyricLine: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var timestamp: TimeInterval
    public var text: String

    public init(id: String = UUID().uuidString, timestamp: TimeInterval, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}
