import Foundation
import PrimuseKit

/// 一次流探测的结果。全部字段都可能缺席 —— 大多数电台只给其中一两项。
struct RadioStreamProbe: Sendable {
    /// `icy-logo` 响应头。Icecast KH 分支会给，直接就是台标地址。
    let logoURL: String?
    /// 带内元数据里的图片地址(`StreamArtwork`，或指向图片的 `StreamUrl`)。
    let inbandArtworkURL: String?
    /// 电台主页(`icy-url`，或非图片的 `StreamUrl`)，留给主页图标抓取。
    let homepageURL: String?
    let stationName: String?
    let streamTitle: String?

    var isEmpty: Bool {
        logoURL == nil && inbandArtworkURL == nil && homepageURL == nil
            && stationName == nil && streamTitle == nil
    }
}

/// 只为了「读一眼电台元数据」而存在的一次性探测：连上去，拿响应头，
/// 顺带读一块带内元数据，然后立刻断开。
///
/// 它刻意不复用播放链路 —— 播放链路要长连、要重连、要喂解码器，而这里要的
/// 恰恰相反：读到就走，绝不占着台方的连接名额，也绝不因为探测失败影响播放。
enum RadioICYProbe {
    /// 最多从流里读这么多字节。带内元数据的间隔(`icy-metaint`)通常是 16000，
    /// 极端的也就 64KB，这个上限足够读到第一块元数据。
    private static let maximumPrefixBytes = 96 * 1024

    /// 探测本身的墙钟上限。电台服务器慢是常态，但慢到这个程度就没有等的价值 ——
    /// 台标只是锦上添花，不值得挂着一个连接。
    private static let defaultTimeout: TimeInterval = 6

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = defaultTimeout * 2
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 失败一律返回 `nil`：探测是纯粹的锦上添花，任何错误都不该向上冒泡。
    static func probe(url: URL, timeout: TimeInterval = defaultTimeout) async -> RadioStreamProbe? {
        // HLS 走的是清单 + 分片，没有 ICY 这一套，连都不用连。
        guard RadioStreamFormat.inferred(from: url) != .hls else { return nil }
        // 明文 HTTP 且用户没授权过这个主机时，传输层会直接拒绝。这里提前退出，
        // 免得为了一张台标去触碰用户没同意过的明文连接。
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            return nil
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        for (name, value) in TVRadioRequestHeaderPolicy.merged(customHeaders: [:]) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (fileURL, response) = try await TrustedHTTPTransport.download(
                for: request,
                session: session,
                wholeResponsePrefixLimit: maximumPrefixBytes
            )
            defer { try? FileManager.default.removeItem(at: fileURL) }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let headers = normalizedHeaders(http)
            let prefix = (try? Data(contentsOf: fileURL)) ?? Data()
            return makeProbe(headers: headers, body: prefix)
        } catch {
            return nil
        }
    }

    private static func makeProbe(headers: [String: String], body: Data) -> RadioStreamProbe? {
        let inband = firstInbandMetadata(headers: headers, body: body) ?? .empty

        // `icy-url` 名义上是主页，个别台往里塞图片 —— 两种都收下。
        let headerLogo = RadioICYHeaderPolicy.logoURL(headers: headers)
            ?? RadioICYHeaderPolicy.inlineLogoURLFromHomepageField(headers: headers)

        let probe = RadioStreamProbe(
            logoURL: headerLogo,
            inbandArtworkURL: inband.artworkURL,
            homepageURL: RadioICYHeaderPolicy.homepageURL(headers: headers) ?? inband.homepageURL,
            stationName: RadioICYHeaderPolicy.stationName(headers: headers),
            streamTitle: inband.streamTitle
        )
        return probe.isEmpty ? nil : probe
    }

    /// 从响应体前缀里切出第一块带内元数据。
    ///
    /// ICY 的格式是「`metaint` 字节音频 + 1 字节长度(单位 16 字节) + 元数据」，
    /// 长度为 0 表示这一轮没有元数据 —— 电台只在内容变化时才推，所以探测
    /// 读到空块是很正常的结果，不算失败。
    private static func firstInbandMetadata(
        headers: [String: String],
        body: Data
    ) -> RadioICYMetadata? {
        guard let interval = RadioICYHeaderPolicy.metadataInterval(headers: headers),
              body.count > interval else {
            return nil
        }
        let lengthIndex = body.index(body.startIndex, offsetBy: interval)
        let blockCount = Int(body[lengthIndex])
        guard blockCount > 0 else { return nil }

        let byteCount = blockCount * 16
        let start = body.index(after: lengthIndex)
        guard body.distance(from: start, to: body.endIndex) >= byteCount else { return nil }
        let end = body.index(start, offsetBy: byteCount)
        return RadioICYMetadataParser.parse(Data(body[start..<end]))
    }

    private static func normalizedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            result[name.lowercased()] = text
        }
        return result
    }
}
