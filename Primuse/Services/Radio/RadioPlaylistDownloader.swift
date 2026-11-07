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
        try await fetchDocument(rawURLString).text
    }

    struct Document: Sendable {
        let text: String
        let url: URL
    }

    struct ImportResult: Sendable {
        let candidates: [RadioImportCandidate]
        let subscriptionURL: String?
    }

    static func importCandidates(_ input: String, existing: [RadioStation], session: URLSession? = nil) async throws -> ImportResult {
        let seed = RadioImportParser.playlistURL(in: input) ?? input
        let initial = RadioImportParser.parse(seed)
        var entries: [RadioImportParser.Entry] = []
        var subscriptionURL: String?
        for candidate in initial {
            try Task.checkCancellation()
            let values: [RadioImportCandidate]
            if candidate.status != .invalid, RadioImportParser.playlistURL(in: candidate.urlString) != nil {
                let document = try await fetchDocument(candidate.urlString, session: session)
                values = RadioImportParser.parse(document.text, baseURL: document.url)
                if initial.count == 1, !MediaImportText.isHLS(document.text) {
                    subscriptionURL = document.url.absoluteString
                }
            } else {
                values = [candidate]
            }
            entries += values.map {
                RadioImportParser.Entry(name: $0.name, urlString: $0.urlString, logoURLString: $0.logoURLString,
                                        homepageURLString: $0.homepageURLString, logoSource: $0.logoSource, groupTitle: $0.groupTitle)
            }
        }
        return ImportResult(candidates: RadioImportParser.candidates(from: entries, existing: existing), subscriptionURL: subscriptionURL)
    }

    static func fetchDocument(_ rawURLString: String, session suppliedSession: URLSession? = nil) async throws -> Document {
        guard let normalized = RadioPlaylistText.normalizedSourceURLString(rawURLString),
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
            session: suppliedSession ?? session,
            maxBytes: RadioPlaylistText.maximumBytes
        )
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard let text = RadioPlaylistText.decode(data) else {
            throw FetchError.undecodable
        }
        return Document(text: text, url: response.url ?? url)
    }
}
