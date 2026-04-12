import Foundation

extension TimeInterval {
    static func sanitized(_ value: TimeInterval?) -> TimeInterval {
        guard let value, value.isFinite else { return 0 }
        return max(0, value)
    }

    var sanitizedDuration: TimeInterval {
        Self.sanitized(self)
    }

    var formattedDuration: String {
        let totalSeconds = Int(sanitizedDuration.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedShort: String {
        let totalSeconds = Int(sanitizedDuration.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
