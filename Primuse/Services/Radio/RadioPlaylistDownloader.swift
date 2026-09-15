import Foundation
import PrimuseKit

/// 从一个 http(s) 地址取回电台清单文本(m3u / m3u8 / pls / txt)。
///
/// 社区维护的电台清单大多挂在 GitHub 或者某个静态站上，地址长期不变、内容
/// 时不时更新。让用户直接填地址，比每次手工下载再选文件少两步。
///
/// 只取文本、不落盘：清单解析完就变成候选列表，原文没有保留价值。
enum RadioPlaylistDownloader {
    enum FetchError: LocalizedError, Equatable {
        case invalidURL
        case httpStatus(Int)
        case undecodable

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "radio_batch_url_invalid")
            case .httpStatus(let code):
                return String(
                    format: String(localized: "radio_batch_url_status %lld"),
                    code
                )
            case .undecodable:
                return String(localized: "radio_batch_file_unreadable")
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    /// 明文 http 的清单地址走和电台流同一套「用户显式信任过的主机」通道，
    /// 所以这里可能抛出 `TrustedHTTPTransportError.permissionRequired`，
    /// 由界面去问用户要不要信任这个主机。
    static func fetch(_ rawURLString: String) async throws -> String {
        guard let normalized = RadioStationValidation.normalizedURLString(rawURLString),
              let url = URL(string: normalized) else {
            throw FetchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(
            "audio/x-mpegurl,application/vnd.apple.mpegurl,text/plain;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: session,
            maxBytes: RadioPlaylistText.maximumBytes
        )
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard let text = RadioPlaylistText.decode(data) else {
            throw FetchError.undecodable
        }
        return text
    }
}
