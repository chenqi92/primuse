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
    /// 清单里写明的台标地址(`tvg-logo`)，或在线目录给的 favicon。
    /// 批量添加页直接用它显示缩略图 —— 用户在勾选前就能看到台标。
    public var logoURLString: String?
    /// 电台主页。没有台标时留给后续的主页图标抓取当输入。
    public var homepageURLString: String?
    /// 台标是从哪来的，决定它在自动发现里的可信度。
    public var logoSource: RadioLogoSource?
    /// 清单里写的分组(`group-title` 或 `#EXTGRP:`)。导入时可以直接当文件夹用 ——
    /// 一份几百条的 IPTV 清单，分组是它自带的唯一整理方式，丢掉太可惜。
    public var groupTitle: String?

    public init(
        id: UUID = UUID(),
        name: String,
        urlString: String,
        status: Status,
        duplicateOfName: String? = nil,
        logoURLString: String? = nil,
        homepageURLString: String? = nil,
        logoSource: RadioLogoSource? = nil,
        groupTitle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.status = status
        self.duplicateOfName = duplicateOfName
        self.logoURLString = logoURLString
        self.homepageURLString = homepageURLString
        self.logoSource = logoSource
        self.groupTitle = groupTitle
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

    /// 一条待判重的结构化条目。在线目录搜索不必把结果拼回文本再解析一遍 ——
    /// 直接构造这个类型，就能和清单导入共用同一套判重与归一化。
    public struct Entry: Equatable, Sendable {
        public var name: String?
        public var urlString: String
        public var logoURLString: String?
        public var homepageURLString: String?
        public var logoSource: RadioLogoSource?
        public var groupTitle: String?

        public init(
            name: String? = nil,
            urlString: String,
            logoURLString: String? = nil,
            homepageURLString: String? = nil,
            logoSource: RadioLogoSource? = nil,
            groupTitle: String? = nil
        ) {
            self.name = name
            self.urlString = urlString
            self.logoURLString = logoURLString
            self.homepageURLString = homepageURLString
            self.logoSource = logoSource
            self.groupTitle = groupTitle
        }
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
        let entries: [Entry]
        switch source ?? detectSource(normalized) {
        case .plainText: entries = parsePlainText(normalized)
        case .m3u: entries = parseM3U(normalized)
        case .pls: entries = parsePLS(normalized)
        }
        return candidates(from: entries, existing: existing)
    }

    /// 结构化条目 → 候选。判重、归一化、名字推断都只有这一份实现。
    public static func candidates(
        from entries: [Entry],
        existing: [RadioStation] = []
    ) -> [RadioImportCandidate] {
        // 判重用归一化 URL 作键。库里同一个流可能被存过两次(名字不同)，
        // 取第一个作为"跟谁重了"的展示对象即可。
        var seen: [String: String] = [:]
        for station in existing {
            guard let key = streamIdentityKey(station.streamURL) else { continue }
            if seen[key] == nil { seen[key] = station.name }
        }

        return entries.map { entry in
            let logo = RadioLogoURLPolicy.normalized(entry.logoURLString)
            let homepage = RadioLogoURLPolicy.normalized(entry.homepageURLString)
            // 只有真的拿到台标地址才记来源，否则来源字段会骗人。
            let logoSource = logo == nil ? nil : (entry.logoSource ?? .importedManifest)
            // 分组名按文件夹名的规矩清洗一遍，导入时可以原样当文件夹用。
            let group = RadioStationOrganization.normalizedFolderName(entry.groupTitle)

            guard let normalizedURL = RadioStationValidation.normalizedURLString(entry.urlString) else {
                return RadioImportCandidate(
                    name: entry.name ?? entry.urlString,
                    urlString: entry.urlString,
                    status: .invalid,
                    logoURLString: logo,
                    homepageURLString: homepage,
                    logoSource: logoSource,
                    groupTitle: group
                )
            }
            let name = entry.name.map(RadioStationValidation.normalizedName)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? suggestedName(for: normalizedURL)

            guard let key = streamIdentityKey(normalizedURL) else {
                return RadioImportCandidate(
                    name: name,
                    urlString: normalizedURL,
                    status: .invalid,
                    logoURLString: logo,
                    homepageURLString: homepage,
                    logoSource: logoSource,
                    groupTitle: group
                )
            }
            if let owner = seen[key] {
                return RadioImportCandidate(
                    name: name,
                    urlString: normalizedURL,
                    status: .duplicate,
                    duplicateOfName: owner,
                    logoURLString: logo,
                    homepageURLString: homepage,
                    logoSource: logoSource,
                    groupTitle: group
                )
            }
            seen[key] = name
            return RadioImportCandidate(
                name: name,
                urlString: normalizedURL,
                status: .playable,
                logoURLString: logo,
                homepageURLString: homepage,
                logoSource: logoSource,
                groupTitle: group
            )
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
    ///
    /// 批量添加和清单订阅共用这一份：订阅电台在清单里的身份
    /// (`RadioStation.subscriptionEntryKey`)、订阅本身的 id 都从它派生，
    /// 两边规则一旦分叉，同一个流就会在两条路径上被当成两个电台。
    public static func streamIdentityKey(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let port = url.port.map { ":\($0)" } ?? ""
        let query = url.query.map { "?\($0)" } ?? ""
        return host + port + path + query
    }

    // MARK: - 播放列表包装

    /// `.pls` / `.m3u` 地址指向的是一份写着真实流地址的小清单(SHOUTcast 目录的
    /// `tunein-station.pls?id=` 就是这种),播放器不认,要先取回来拆开。`.m3u8` 是 HLS,
    /// 本身就能播,不算包装。
    public static func isPlaylistWrapper(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return ["pls", "m3u"].contains(url.pathExtension.lowercased())
    }

    /// 取包装清单时依次尝试的地址:明文地址先试一次 https。清单是公开内容,升级不泄露
    /// 什么;而明文主机要用户单独信任过才能访问,后台同步时没法去问。
    public static func wrapperFetchURLs(_ urlString: String) -> [String] {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              var components = URLComponents(string: normalized) else { return [] }
        guard components.scheme?.lowercased() == "http" else { return [normalized] }
        components.scheme = "https"
        // 显式写了 80 端口的,换到 https 就不能还连 80。
        if components.port == 80 { components.port = nil }
        guard let upgraded = components.string else { return [normalized] }
        return [upgraded, normalized]
    }

    /// 拆开后的第一条可播地址;清单里嵌套的包装不算。
    public static func firstStreamURL(inWrapper text: String) -> String? {
        parse(text).first { $0.status == .playable && !isPlaylistWrapper($0.urlString) }?.urlString
    }

    /// 按 `wrapperFetchURLs` 的顺序取清单并拆开,一个地址取不到或拆不开就试下一个;
    /// 都不行时返回 nil。取数由调用方给:各端的明文主机信任方式不同。
    public static func unwrappedStreamURL(
        _ urlString: String,
        fetch: @Sendable (String) async throws -> String
    ) async throws -> String? {
        for candidate in wrapperFetchURLs(urlString) {
            try Task.checkCancellation()
            let text: String
            do {
                text = try await fetch(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            if let stream = firstStreamURL(inWrapper: text) { return stream }
        }
        return nil
    }

    // MARK: - 各格式解析

    private static func parsePlainText(_ text: String) -> [Entry] {
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
                    return Entry(name: head, urlString: tail)
                }
            }
            return Entry(urlString: line)
        }
    }

    /// `#EXTINF:<秒>,<名字>` 后面紧跟的那一行是 URL。没有 EXTINF 的裸 URL 也收。
    ///
    /// EXTINF 的属性区(`tvg-logo="..."` / `group-title="..."`)是 IPTV 与电台清单
    /// 里最常见的台标和分组来源，单独的 `#EXTIMG:` / `#EXTGRP:` 行也有播放器在用。
    ///
    /// 属性区和名字的分界见 `nameSeparatorIndex`：按最后一个逗号切会把
    /// `Radio X, Sydney` 砍成「Sydney」，按第一个切又会把 `a="x",b="y",Name`
    /// 的属性当成名字。
    private static func parseM3U(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var pendingName: String?
        var pendingLogo: String?
        var pendingGroup: String?
        // `#EXTGRP:` 按约定一直作用到下一个 `#EXTGRP:`，所以它要跨条目保留；
        // `group-title` 是写在条目自己身上的，只作用于紧跟的那一条。
        var runningGroup: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let lowered = line.lowercased()
            if lowered.hasPrefix("#extinf") {
                guard let commaIndex = nameSeparatorIndex(in: line) else { continue }
                let name = String(line[line.index(after: commaIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                pendingName = name.isEmpty ? nil : name
                let attributes = String(line[line.startIndex..<commaIndex])
                pendingLogo = pendingLogo ?? attributeValue(
                    in: attributes,
                    keys: ["tvg-logo", "logo", "tvg-logo-small", "url-logo", "icon"]
                )
                pendingGroup = pendingGroup ?? attributeValue(
                    in: attributes,
                    keys: ["group-title", "tvg-group", "group"]
                )
                continue
            }
            if lowered.hasPrefix("#extimg") {
                let value = line.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                pendingLogo = pendingLogo ?? (value.isEmpty ? nil : value)
                continue
            }
            if lowered.hasPrefix("#extgrp") {
                let value = line.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                runningGroup = value.isEmpty ? nil : value
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            entries.append(Entry(
                name: pendingName,
                urlString: line,
                logoURLString: pendingLogo,
                groupTitle: pendingGroup ?? runningGroup
            ))
            pendingName = nil
            pendingLogo = nil
            pendingGroup = nil
        }
        return entries
    }

    /// 属性区和名字的分界逗号。
    ///
    /// 两种真实写法必须同时照顾到，而光看逗号位置分不开它们：
    /// - `tvg-id="a",tvg-name="b",Real Name` —— 逗号是属性之间的分隔符；
    /// - `group-title="Pop, Rock" tvg-logo="…",Radio X, Sydney` —— 台名自带逗号。
    ///
    /// 所以规则是：跳过引号里的逗号，再看每个逗号**后面**像不像又一条 `键=值`；
    /// 像就继续往后找，不像就是名字的开头。引号不成对(清单里少写一个引号很常见)
    /// 时退回第一个逗号，总比整行解析失败强。
    private static func nameSeparatorIndex(in line: String) -> String.Index? {
        var quote: Character?
        var firstUnquoted: String.Index?
        var firstAny: String.Index?
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                if firstUnquoted == nil { firstUnquoted = index }
                if !looksLikeAttributeAssignment(line[line.index(after: index)...]) {
                    return index
                }
            }
            if character == ",", firstAny == nil { firstAny = index }
            index = line.index(after: index)
        }
        return firstUnquoted ?? firstAny
    }

    /// 这一段是不是以 `键=` 开头。是的话它属于属性区，不是名字。
    private static func looksLikeAttributeAssignment(_ rest: Substring) -> Bool {
        var slice = rest.drop { $0 == " " || $0 == "\t" }
        let key = slice.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !key.isEmpty else { return false }
        slice = slice.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        return slice.first == "="
    }

    /// `FileN=` 是 URL，`TitleN=` 是同一个 N 的名字，顺序不保证，所以先按序号收集。
    /// `LogoN=` / `ImageN=` 不是 PLS 标准字段，但有导出工具会写，顺手收下。
    private static func parsePLS(_ text: String) -> [Entry] {
        var urls: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var logos: [Int: String] = [:]

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
            } else if key.hasPrefix("logo"), let index = Int(key.dropFirst(4)) {
                logos[index] = value
            } else if key.hasPrefix("image"), let index = Int(key.dropFirst(5)) {
                logos[index] = logos[index] ?? value
            }
        }

        return urls.keys.sorted().map { index in
            Entry(
                name: titles[index],
                urlString: urls[index] ?? "",
                logoURLString: logos[index]
            )
        }
    }

    /// 从 EXTINF 属性区里取一个属性值。同一个概念在不同导出工具里叫法不一样，
    /// 所以按优先级给一串候选键；值可能用双引号、单引号，或者干脆不加引号。
    private static func attributeValue(in attributes: String, keys: [String]) -> String? {
        for key in keys {
            guard let range = attributes.range(of: "\(key)=", options: .caseInsensitive) else {
                continue
            }
            // 属性名必须是完整的一段，否则 `logo=` 会命中 `tvg-logo=` 的尾巴，
            // 把值切成半截；`group=` 同理会命中 `group-title=` 之外的写法。
            if range.lowerBound > attributes.startIndex {
                let previous = attributes[attributes.index(before: range.lowerBound)]
                guard previous.isWhitespace || previous == ":" || previous == "," else { continue }
            }
            var rest = attributes[range.upperBound...]
            guard let first = rest.first else { continue }
            if first == "\"" || first == "'" {
                rest = rest.dropFirst()
                guard let end = rest.firstIndex(of: first) else { continue }
                let value = String(rest[rest.startIndex..<end]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            } else {
                let value = String(rest.prefix { !$0.isWhitespace })
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
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
