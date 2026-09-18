import Foundation
import PrimuseKit

// MARK: - 群晖 Audio Station 错误文案

/// Kit 里的错误只带结构化信息,界面文案在这里给。iPhone、Mac 与 Apple TV 共用
/// 这一份:电视端的扫描、测试连接与播放失败都直接显示它的错误描述。文案都在
/// App 的 Localizable 表里,Apple TV 的资源里同样打包了这张表。
extension SynologyAudioStationError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return String(localized: "audio_station_error_missing_credential")
        case .invalidURL:
            return String(localized: "synology_error_invalid_url")
        case .invalidResponse, .rangeNotSupported, .transcodeRequired:
            return String(localized: "synology_error_invalid_response")
        case .badServerResponse(let status):
            return String(format: String(localized: "synology_error_http_format"), status)
        case .audioStationUnavailable:
            return String(localized: "audio_station_error_unavailable")
        case .unsupportedVersion:
            return String(localized: "audio_station_error_unsupported_version")
        case .apiNotFound(let code):
            return String(format: String(localized: "audio_station_error_api_not_found_format"), code)
        case .twoFactorRequired:
            return String(localized: "audio_station_error_two_factor_required")
        case .invalidOneTimePassword:
            return String(localized: "synology_auth_error_404")
        case .invalidCredentials:
            return String(localized: "synology_auth_error_400")
        case .accountDisabled:
            return String(localized: "synology_auth_error_401")
        case .noAudioStationPermission:
            return String(localized: "audio_station_error_no_permission")
        case .operationNotPermitted:
            return String(localized: "audio_station_error_operation_not_permitted")
        case .sessionExpired:
            return String(localized: "audio_station_error_session_expired")
        case .ipBlocked:
            return String(localized: "synology_auth_error_407")
        case .passwordExpired(let code):
            switch code {
            case 408: return String(localized: "synology_auth_error_408")
            case 409: return String(localized: "synology_auth_error_409")
            default: return String(localized: "synology_auth_error_410")
            }
        case .serverBusy:
            return String(localized: "audio_station_error_server_busy")
        case .duplicateInPlaylist:
            return String(format: String(localized: "audio_station_error_server_format"), 411)
        case .server(let code):
            return String(format: String(localized: "audio_station_error_server_format"), code)
        }
    }
}
