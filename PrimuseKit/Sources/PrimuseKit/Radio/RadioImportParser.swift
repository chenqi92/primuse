import Foundation

/// 批量添加电台时的一条候选。`status` 决定 UI 里那枚彩色标签，也决定默认是否勾选 ──
/// 只有 `.playable` 默认勾上，重复和无效的留给用户自己决定。
public struct RadioImportCandidate: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        /// 可用 ── URL 合法且库里没有、批次内也没重复。
        case playable
        /// 重复 ── 归一化 URL 与已有电台或本批次前面的条目相同。
        case duplicate
        /// 无效 ── 不是 http(s)、缺 host、带用户名密码，或压根解不出 URL。
        case invalid
    }

    public let id: UUID
    /// 展示用名字。来源优先级：清单里的显式标题 > 从 URL 猜的名字。
    public var name: String
    /// 归一化后的 URL 字符串；`.invalid` 时保留用户原始输入好让人看出哪行写错了。
    public var urlString: String
    public var status: Status
    /// 重复时指向已有电台的名字，UI 用它说明"跟谁重了"。
    public var duplicateOfName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        urlString: String,
        status: Status,
        duplicateOfName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.status = status
        self.duplicateOfName = duplicateOfName
    }

    public var isPlayable: Bool { status == .playable }
}

/// 把用户粘贴的一坨文本 / m3u / pls 变成候选列表。
///
/// 纯函数，没有 I/O 也不碰 store ── 调用方把「已有电台」作为参数传进来，
/// 这样同一套判重逻辑既能在批量添加页用，也能在单测里跑。
public enum RadioImportParser {
    /// 支持的清单格式。`plainText` 是兜底：一行一个 URL，可选 `名字, URL` /
    /// `名字 | URL` / `名字<TAB>URL` 前缀。
    public enum Source: Sendable {
        case plainText
        case m3u
        case pls
    }

    /// 按内容特征猜格式，让"粘贴"和"选文件"走同一个入口。
    public static func detectSource(_ text: String) -> Source {
        let head = text.prefix(4_096).lowercased()
        if head.contains("#extm3u") || head.contains("#extinf") { return .m3u }
        if head.contains("[playlist]") || head.contains("file1=") { return .pls }
        return .plainText
    }

    /// 解析并判重。`existing` 一般传 `store.stations`。
    public static func parse(
        _ text: String,
        existing: [RadioStation] = [],
        source: Source? = nil
    ) -> [RadioImportCandidate] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let entries: [RawEntry]
        switch source ?? detectSource(normalized) {
        case .plainText: entries = parsePlainText(normalized)
        case .m3u: entries = parseM3U(normalized)
        case .pls: entries = parsePLS(normalized)
        }

        // 判重用归一化 URL 作键。库里同一个流可能被存过两次(名字不同)，
        // 取第一个作为"跟谁重了"的展示对象即可。
        var seen: [String: String] = [:]
        for station in existing {
            guard let key = duplicateKey(station.streamURL) else { continue }
            if seen[key] == nil { seen[key] = station.name }
        }

        return entries.map { entry in
            guard let normalizedURL = RadioStationValidation.normalizedURLString(entry.urlString) else {
                return RadioImportCandidate(
                    name: entry.name ?? entry.urlString,
                    urlString: entry.urlString,
                    status: .invalid
                )
            }
            let name = entry.name.map(RadioStationValidation.normalizedName)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? suggestedName(for: normalizedURL)

            guard let key = duplicateKey(normalizedURL) else {
                return RadioImportCandidate(name: name, urlString: normalizedURL, status: .invalid)
            }
            if let owner = seen[key] {
                return RadioImportCandidate(
                    name: name,
                    urlString: normalizedURL,
                    status: .duplicate,
                    duplicateOfName: owner
                )
            }
            seen[key] = name
            return RadioImportCandidate(name: name, urlString: normalizedURL, status: .playable)
        }
    }

    /// 从 URL 猜一个人能读的名字。优先最后一段路径(电台流常见 `groovesalad-128`)，
    /// 退回 host 去掉 `www.` 和常见流媒体前缀。
    public static func suggestedName(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let lastComponent = url.pathComponents
            .last { !$0.isEmpty && $0 != "/" && !$0.lowercased().hasPrefix("index") }
        if let lastComponent {
            let stem = (lastComponent as NSString).deletingPathExtension
            let cleaned = stem
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.count >= 3, cleaned.rangeOfCharacter(from: .letters) != nil {
                return cleaned.capitalizedFirstWords()
            }
        }
        guard var host = url.host, !host.isEmpty else { return urlString }
        for prefix in ["www.", "ice.", "ice1.", "ice2.", "ice5.", "stream.", "streaming.", "live."] {
            if host.lowercased().hasPrefix(prefix) {
                host.removeFirst(prefix.count)
                break
            }
        }
        return host
    }

    // MARK: - 判重键

    /// scheme 和末尾斜杠不参与判重 ── 同一个流的 http / https 两种写法算重复，
    /// 否则用户粘一份 http 一份 https 会得到两个播一样内容的电台。
    private static func duplicateKey(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let port = url.port.map { ":\($0)" } ?? ""
        let query = url.query.map { "?\($0)" } ?? ""
        return host + port + path + query
    }

    // MARK: - 各格式解析

    private struct RawEntry {
        var name: String?
        var urlString: String
    }

    private static func parsePlainText(_ text: String) -> [RawEntry] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { return nil }

            // `名字, URL` / `名字 | URL` / `名字\tURL`。分隔符右边必须像 URL，
            // 否则整行按 URL 处理 —— 电台流路径里逗号并不罕见。
            for separator in ["\t", " | ", "|", ", ", ","] {
                guard let range = line.range(of: separator) else { continue }
                let head = String(line[line.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let tail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if looksLikeURL(tail), !head.isEmpty, !looksLikeURL(head) {
                    return RawEntry(name: head, urlString: tail)
                }
            }
            return RawEntry(name: nil, urlString: line)
        }
    }

    /// `#EXTINF:<秒>,<名字>` 后面紧跟的那一行是 URL。没有 EXTINF 的裸 URL 也收。
    private static func parseM3U(_ text: String) -> [RawEntry] {
        var entries: [RawEntry] = []
        var pendingName: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.lowercased().hasPrefix("#extinf") {
                // 逗号后面才是名字；逗号前是时长和可选的属性(可能自带逗号，
                // 所以取最后一个逗号之后的内容)。
                if let commaIndex = line.lastIndex(of: ",") {
                    let name = String(line[line.index(after: commaIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    pendingName = name.isEmpty ? nil : name
                }
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            entries.append(RawEntry(name: pendingName, urlString: line))
            pendingName = nil
        }
        return entries
    }

    /// `FileN=` 是 URL，`TitleN=` 是同一个 N 的名字，顺序不保证，所以先按序号收集。
    private static func parsePLS(_ text: String) -> [RawEntry] {
        var urls: [Int: String] = [:]
        var titles: [Int: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equalsIndex]).lowercased()
            let value = String(line[line.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            if key.hasPrefix("file"), let index = Int(key.dropFirst(4)) {
                urls[index] = value
            } else if key.hasPrefix("title"), let index = Int(key.dropFirst(5)) {
                titles[index] = value
            }
        }

        return urls.keys.sorted().map { index in
            RawEntry(name: titles[index], urlString: urls[index] ?? "")
        }
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}

private extension String {
    /// `groove salad` → `Groove Salad`。只动首字母，已经有大写的词保持原样
    /// (`BBC` 不该变成 `Bbc`)。
    func capitalizedFirstWords() -> String {
        split(separator: " ", omittingEmptySubsequences: true)
            .map { word -> String in
                guard let first = word.first, first.isLowercase else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
