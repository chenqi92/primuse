import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 简介写到文件夹里的 `album.nfo` / `artist.nfo`(Kodi 的约定,Jellyfin、Emby 也读),
/// 扫到别人整理好的 nfo 也能读回来。只动简介和风格这几个元素,文件里其它内容原样保留。
public enum LibraryInsightNFO {
    public static let maximumReadBytes = 512 * 1024

    public static func fileName(for kind: LibraryInsightKind) -> String {
        kind == .album ? "album.nfo" : "artist.nfo"
    }

    static func rootName(for kind: LibraryInsightKind) -> String {
        kind == .album ? "album" : "artist"
    }

    static func summaryElement(for kind: LibraryInsightKind) -> String {
        kind == .album ? "review" : "biography"
    }

    /// 读出简介和风格标签;不是这一类 nfo、或者两样都没有时返回 nil。
    public static func read(_ text: String, kind: LibraryInsightKind) -> (summary: String, tags: [String])? {
        guard let root = XMLTree.parse(text), root.name.lowercased() == rootName(for: kind) else { return nil }
        let summary = root.firstChild(named: summaryElement(for: kind))?.text ?? ""
        let tags = root.children(named: "style").map(\.text) + root.children(named: "mood").map(\.text)
        let cleanedSummary = LibraryInsightEditing.normalizedSummary(plainText(fromMarkup: summary))
        let cleanedTags = LibraryInsightEditing.normalizedTags(tags)
        guard !cleanedSummary.isEmpty || !cleanedTags.isEmpty else { return nil }
        return (cleanedSummary, cleanedTags)
    }

    /// 写进已有的 nfo(保留其它元素)或新建一份。已有文件读不成这一类 XML 时返回 nil,
    /// 不去覆盖别人的文件(有些 nfo 只是一行网址)。
    public static func updatedDocument(
        existing: String?,
        kind: LibraryInsightKind,
        title: String,
        artist: String,
        summary: String,
        tags: [String]
    ) -> String? {
        let rootName = rootName(for: kind)
        let root: XMLTree.Element
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = XMLTree.parse(existing), parsed.name.lowercased() == rootName else { return nil }
            root = parsed
        } else {
            root = XMLTree.Element(name: rootName)
        }

        switch kind {
        case .album:
            if root.firstChild(named: "title") == nil, !title.isEmpty {
                root.append(XMLTree.Element(name: "title", text: title))
            }
            if root.firstChild(named: "artist") == nil, root.firstChild(named: "albumArtistCredits") == nil,
               !artist.isEmpty {
                root.append(XMLTree.Element(name: "artist", text: artist))
            }
        case .artist:
            if root.firstChild(named: "name") == nil, !artist.isEmpty {
                root.append(XMLTree.Element(name: "name", text: artist))
            }
        }

        let summaryName = summaryElement(for: kind)
        if summary.isEmpty {
            root.removeChildren(named: summaryName)
        } else if let element = root.firstChild(named: summaryName) {
            element.setText(summary)
            root.removeChildren(named: summaryName, keepingFirst: true)
        } else {
            root.append(XMLTree.Element(name: summaryName, text: summary))
        }

        // 风格整组换掉,放在原来第一个风格的位置(没有就接在简介后面)。
        let anchor = root.index(ofFirstChildNamed: "style")
            ?? root.index(ofFirstChildNamed: summaryName).map { $0 + 1 }
        root.removeChildren(named: "style")
        let styles = tags.map { XMLTree.Element(name: "style", text: $0) }
        root.insert(styles, at: min(anchor ?? root.childCount, root.childCount))

        return XMLTree.document(root)
    }

    /// nfo 或服务器上的简介偶尔带 HTML(网站抓来的)或 Kodi 的 [B] 标记,只留文字。
    public static func plainText(fromMarkup text: String) -> String {
        var result = text.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[/?(B|I|U|CR|COLOR[^\\]]*)\\]", with: "", options: [.regularExpression, .caseInsensitive])
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

/// 专辑、艺人在音乐源上对应哪个文件夹。宁可不写也不写错地方:
/// 判断不了就返回 nil。
public enum LibraryInsightFolderPolicy {
    /// 曲目所在的文件夹:同在一个文件夹;或者分在「CD1」「Disc 2」这类碟片子文件夹里,取上一级。
    /// 还没核对文件夹里有没有别的专辑。
    public static func candidateAlbumFolder(trackPaths: [String]) -> String? {
        let directories = Set(trackPaths.map(parent).filter { !$0.isEmpty })
        guard !directories.isEmpty else { return nil }
        let folder: String
        if directories.count == 1, let only = directories.first {
            folder = only
        } else {
            let parents = Set(directories.map(parent))
            guard parents.count == 1, let common = parents.first,
                  directories.allSatisfy({ isDiscFolderName(lastComponent($0)) }) else { return nil }
            folder = common
        }
        return isUsableFolder(folder) ? folder : nil
    }

    /// 专辑文件夹:候选文件夹里(含碟片子文件夹)没有别的专辑的歌才算,
    /// 所有歌平铺在一个文件夹里时就不写。
    public static func albumFolder(trackPaths: [String], otherAlbumTrackPaths: [String]) -> String? {
        guard let folder = candidateAlbumFolder(trackPaths: trackPaths) else { return nil }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let shared = otherAlbumTrackPaths.contains { path in
            let directory = parent(path)
            return directory == folder || (directory.hasPrefix(prefix) && isDiscFolderName(lastComponent(directory)))
        }
        return shared ? nil : folder
    }

    /// 艺人文件夹:文件夹名就是艺人名(忽略大小写、全半角、空白与标点)。
    /// 每张专辑的文件夹要么就是它(歌直接放在艺人文件夹里),要么是它的子文件夹;
    /// 对不上就不写,免得写进「音乐」这类总目录。
    public static func artistFolder(albumFolders: [String], artistName: String) -> String? {
        let artistKey = SongDiscoveryMatching.key(artistName)
        guard !artistKey.isEmpty, !albumFolders.isEmpty else { return nil }
        func matches(_ folder: String) -> Bool {
            isUsableFolder(folder) && SongDiscoveryMatching.key(lastComponent(folder)) == artistKey
        }
        let resolved = Set(albumFolders.map { folder -> String in
            matches(folder) ? folder : parent(folder)
        })
        guard resolved.count == 1, let folder = resolved.first, matches(folder) else { return nil }
        return folder
    }

    public static func filePath(in folder: String, kind: LibraryInsightKind) -> String {
        (folder.hasSuffix("/") ? folder : folder + "/") + LibraryInsightNFO.fileName(for: kind)
    }

    static func isDiscFolderName(_ name: String) -> Bool {
        name.range(
            of: #"^(cd|disc|disk|dvd|碟|光盘|ディスク)\s*[-_.#]?\s*\d{1,2}(\s.*)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func parent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        let result = String(trimmed[..<slash])
        return result.isEmpty ? "/" : result
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func isUsableFolder(_ folder: String) -> Bool {
        !folder.isEmpty && folder != "/" && !lastComponent(folder).isEmpty
    }
}

/// 写回开关。
public enum LibraryInsightWritebackPolicy {
    /// 写进 album.nfo / artist.nfo,以及 Jellyfin、Emby、Plex 的简介。默认开。
    public static let fileWriteEnabledKey = "primuse.sidecar.insightWriteEnabled"
    /// 专辑简介同时写进每首歌的「注释」。默认关:要整首下载、改写、再上传,还会覆盖原来的注释。
    public static let embedCommentEnabledKey = "primuse.insight.embedCommentEnabled"

    public static func writesFiles(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: fileWriteEnabledKey) == nil ? true : defaults.bool(forKey: fileWriteEnabledKey)
    }

    public static func embedsComment(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: embedCommentEnabledKey)
    }
}

/// 只够读写 nfo 的极简 XML 树:元素、文字、注释按原顺序保留。
enum XMLTree {
    final class Element {
        var name: String
        var attributes: [(String, String)]
        var nodes: [Node]

        enum Node {
            case element(Element)
            case text(String)
            case comment(String)
        }

        init(name: String, attributes: [(String, String)] = [], text: String? = nil) {
            self.name = name
            self.attributes = attributes
            self.nodes = text.map { [.text($0)] } ?? []
        }

        var text: String {
            nodes.map { node -> String in
                switch node {
                case .text(let value): return value
                case .element(let child): return child.text
                case .comment: return ""
                }
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var childCount: Int { nodes.count }

        func setText(_ value: String) {
            nodes = [.text(value)]
        }

        func children(named name: String) -> [Element] {
            nodes.compactMap {
                if case .element(let child) = $0, child.name.caseInsensitiveCompare(name) == .orderedSame { return child }
                return nil
            }
        }

        func firstChild(named name: String) -> Element? { children(named: name).first }

        func index(ofFirstChildNamed name: String) -> Int? {
            nodes.firstIndex {
                if case .element(let child) = $0 { return child.name.caseInsensitiveCompare(name) == .orderedSame }
                return false
            }
        }

        func append(_ element: Element) {
            nodes.append(.element(element))
        }

        func insert(_ elements: [Element], at index: Int) {
            nodes.insert(contentsOf: elements.map { .element($0) }, at: index)
        }

        func removeChildren(named name: String, keepingFirst: Bool = false) {
            var kept = !keepingFirst
            nodes.removeAll { node in
                guard case .element(let child) = node,
                      child.name.caseInsensitiveCompare(name) == .orderedSame else { return false }
                if !kept { kept = true; return false }
                return true
            }
        }
    }

    static func parse(_ text: String) -> Element? {
        guard let data = text.data(using: .utf8) else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), builder.depthError == false else { return nil }
        return builder.root
    }

    static func document(_ root: Element) -> String {
        var output = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        write(root, depth: 0, into: &output)
        return output
    }

    private static func write(_ element: Element, depth: Int, into output: inout String) {
        let indent = String(repeating: "    ", count: depth)
        let attributes = element.attributes.map { " \($0.0)=\"\(escape($0.1, attribute: true))\"" }.joined()
        let childElements = element.nodes.contains { if case .element = $0 { return true }; return false }
        if !childElements {
            let text = element.nodes.compactMap { node -> String? in
                if case .text(let value) = node { return value }
                return nil
            }.joined()
            output += "\(indent)<\(element.name)\(attributes)>\(escape(text, attribute: false))</\(element.name)>\n"
            return
        }
        output += "\(indent)<\(element.name)\(attributes)>\n"
        for node in element.nodes {
            switch node {
            case .element(let child):
                write(child, depth: depth + 1, into: &output)
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    output += "\(indent)    \(escape(trimmed, attribute: false))\n"
                }
            case .comment(let value):
                output += "\(indent)    <!--\(value)-->\n"
            }
        }
        output += "\(indent)</\(element.name)>\n"
    }

    private static func escape(_ text: String, attribute: Bool) -> String {
        var result = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            result = result.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return result
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Element?
        var stack: [Element] = []
        var depthError = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard stack.count < 64 else {
                depthError = true
                parser.abortParsing()
                return
            }
            let element = Element(
                name: elementName,
                attributes: attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            )
            if let parent = stack.last {
                parent.nodes.append(.element(element))
            } else if root == nil {
                root = element
            }
            stack.append(element)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            appendText(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, foundComment comment: String) {
            stack.last?.nodes.append(.comment(comment))
        }

        private func appendText(_ string: String) {
            guard let current = stack.last else { return }
            if case .text(let existing)? = current.nodes.last {
                current.nodes[current.nodes.count - 1] = .text(existing + string)
            } else {
                current.nodes.append(.text(string))
            }
        }
    }
}
