import Foundation

/// 一块 Shoutcast/Icecast 带内元数据解析出来的内容。
///
/// 实际抓包看到的形态(2026-09 采样)：
/// - SomaFM: `StreamTitle='Red Eye Express - Aqua';StreamUrl='https://somafm.com/logos/512/groovesalad512.jpg';`
/// - Shoutcast 面板: `StreamTitle='Paul Brown - The Funky Joint ';StreamUrl='';StreamArtwork='';`
/// - 没配置的台: `StreamUrl='0'`
///
/// 所以 `StreamUrl` 既可能是台标图片，也可能是电台主页，还可能是垃圾占位值 ——
/// 这里按「像不像位图」把它分流到 `artworkURL` 或 `homepageURL`。
public struct RadioICYMetadata: Equatable, Sendable {
    /// `StreamTitle`。通常是「艺术家 - 曲名」，也可能是节目名或一句广告词。
    public let streamTitle: String?
    /// 明确指向一张图的地址(`StreamArtwork`，或看起来是位图的 `StreamUrl`)。
    public let artworkURL: String?
    /// 看起来是网页而不是图片的 `StreamUrl` —— 留给主页图标抓取当输入。
    public let homepageURL: String?

    public init(streamTitle: String?, artworkURL: String?, homepageURL: String?) {
        self.streamTitle = streamTitle
        self.artworkURL = artworkURL
        self.homepageURL = homepageURL
    }

    public static let empty = RadioICYMetadata(
        streamTitle: nil,
        artworkURL: nil,
        homepageURL: nil
    )

    public var isEmpty: Bool {
        streamTitle == nil && artworkURL == nil && homepageURL == nil
    }
}

public enum RadioICYMetadataParser {
    /// 带内元数据块的解析入口。块尾是 NUL 填充，编码没有保证 ——
    /// 先按 UTF-8 试，失败退到 Latin-1(Shoutcast 的历史默认)。
    public static func parse(_ data: Data) -> RadioICYMetadata {
        let trimmed = Data(data.prefix { $0 != 0 })
        guard !trimmed.isEmpty else { return .empty }
        guard let text = String(data: trimmed, encoding: .utf8)
                ?? String(data: trimmed, encoding: .isoLatin1) else {
            return .empty
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> RadioICYMetadata {
        let fields = fields(in: text)
        let title = cleanedTitle(fields["streamtitle"])

        // StreamArtwork 是明确的封面字段，优先于含义含糊的 StreamUrl。
        let artworkField = RadioLogoURLPolicy.normalized(fields["streamartwork"])
        let streamURLField = RadioLogoURLPolicy.normalized(fields["streamurl"])

        var artwork = artworkField
        var homepage: String?
        if let streamURLField {
            if RadioLogoURLPolicy.looksLikeBitmap(streamURLField) {
                artwork = artwork ?? streamURLField
            } else {
                homepage = streamURLField
            }
        }

        return RadioICYMetadata(
            streamTitle: title,
            artworkURL: artwork,
            homepageURL: homepage
        )
    }

    /// `key='value';key='value';` 的容错扫描。
    ///
    /// 不能简单地按 `'` 切 —— 曲名里的撇号(`Don't Stop`)会把值拦腰截断，
    /// 这是旧实现的实际问题。这里以 `';` 作为值的结束标记，只有在剩余文本里
    /// 再也找不到 `';` 时才退回「到最后一个 `'`」。
    public static func fields(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            guard let assign = text.range(of: "='", range: index..<text.endIndex) else { break }

            // 键名 = 赋值号往前一直到分隔符(`;`)或开头。
            let keyStart = text[index..<assign.lowerBound]
                .lastIndex(of: ";")
                .map { text.index(after: $0) } ?? index
            let key = text[keyStart..<assign.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let valueStart = assign.upperBound
            let valueEnd: String.Index
            let nextIndex: String.Index
            if let terminator = text.range(of: "';", range: valueStart..<text.endIndex) {
                valueEnd = terminator.lowerBound
                nextIndex = terminator.upperBound
            } else if let lastQuote = text[valueStart...].lastIndex(of: "'") {
                valueEnd = lastQuote
                nextIndex = text.index(after: lastQuote)
            } else {
                valueEnd = text.endIndex
                nextIndex = text.endIndex
            }

            if !key.isEmpty {
                result[key] = String(text[valueStart..<valueEnd])
            }
            index = nextIndex
        }

        return result
    }

    private static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 流响应头里的电台信息。Icecast KH 分支会给 `icy-logo`(直接就是台标地址)，
/// 大部分服务器只给 `icy-url`(电台主页)，两者都可能缺席。
public enum RadioICYHeaderPolicy {
    public static func logoURL(headers: [String: String]) -> String? {
        RadioLogoURLPolicy.normalized(value(for: "icy-logo", in: headers))
    }

    /// `icy-url` 名义上是电台主页。个别台会往里塞图片地址，所以照样过一遍
    /// 位图判定，是图就当台标用。
    public static func homepageURL(headers: [String: String]) -> String? {
        let raw = RadioLogoURLPolicy.normalized(value(for: "icy-url", in: headers))
        guard let raw, !RadioLogoURLPolicy.looksLikeBitmap(raw) else { return nil }
        return raw
    }

    public static func inlineLogoURLFromHomepageField(headers: [String: String]) -> String? {
        let raw = RadioLogoURLPolicy.normalized(value(for: "icy-url", in: headers))
        guard let raw, RadioLogoURLPolicy.looksLikeBitmap(raw) else { return nil }
        return raw
    }

    public static func stationName(headers: [String: String]) -> String? {
        let raw = value(for: "icy-name", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// 带内元数据的间隔。缺失或非正数表示这个流不推送带内元数据。
    public static func metadataInterval(headers: [String: String]) -> Int? {
        guard let raw = value(for: "icy-metaint", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let interval = Int(raw),
              interval > 0 else {
            return nil
        }
        return interval
    }

    private static func value(for field: String, in headers: [String: String]) -> String? {
        if let exact = headers[field] { return exact }
        let lowered = field.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}
