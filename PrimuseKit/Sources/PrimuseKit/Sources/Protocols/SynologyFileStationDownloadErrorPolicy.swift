import Foundation

public enum SynologyFileStationDownloadErrorDisposition: Sendable, Equatable {
    case reconnectSession
    case missingFile
    case sourceUnavailable
    case fail
}

public enum SynologyFileStationDownloadErrorPolicy {
    public static func disposition(
        code: Int
    ) -> SynologyFileStationDownloadErrorDisposition {
        switch code {
        case 100, 105, 106, 107, 119:
            return .reconnectSession
        case 408:
            return .missingFile
        case 407, 410:
            return .sourceUnavailable
        default:
            return .fail
        }
    }
}
