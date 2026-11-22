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

    /// 一个音乐源里每张专辑的文件夹,和 `albumFolder` 同一套判断,整源一次算完:按目录建索引,
    /// 不用每张专辑都把整源的歌扫一遍。键是调用方给的专辑标识,值是路径列表。
    /// `otherTrackPaths`: 没有专辑标签的歌,和 `albumFolder` 一样算作别的专辑,自己不分文件夹。
    public static func albumFolders(
        tracksByAlbum: [String: [String]],
        otherTrackPaths: [String] = []
    ) -> [String: String] {
        let albums = Array(tracksByAlbum)
        // 专辑换成下标,-1 是没有专辑的歌;每个目录只记两张,够判断「有没有别的专辑」。
        var albumsByDirectory: [String: AlbumPair] = [:]
        for (index, entry) in albums.enumerated() {
            for path in entry.value { albumsByDirectory[parent(path), default: AlbumPair()].insert(index) }
        }
        for path in otherTrackPaths { albumsByDirectory[parent(path), default: AlbumPair()].insert(-1) }
        // 碟片目录里的专辑记到它的每一级上级目录:`albumFolder` 把候选文件夹下面任何一层的碟片目录都算进来。
        var discAlbumsBelow: [String: AlbumPair] = [:]
        for (directory, pair) in albumsByDirectory where isDiscFolderName(lastComponent(directory)) {
            var ancestor = parent(directory)
            while !ancestor.isEmpty, ancestor != "/" {
                discAlbumsBelow[ancestor, default: AlbumPair()].formUnion(pair)
                ancestor = parent(ancestor)
            }
        }
        var folders: [String: String] = [:]
        for (index, entry) in albums.enumerated() {
            guard let folder = candidateAlbumFolder(trackPaths: entry.value) else { continue }
            let shared = albumsByDirectory[folder]?.containsOther(than: index) == true
                || discAlbumsBelow[folder]?.containsOther(than: index) == true
            if !shared { folders[entry.key] = folder }
        }
        return folders
    }

    /// 最多记两张专辑:有两张时对任何一张来说都有「别的专辑」。
    private struct AlbumPair {
        var first: Int?
        var second: Int?

        mutating func insert(_ album: Int) {
            if first == nil {
                first = album
            } else if second == nil, first != album {
                second = album
            }
        }

        mutating func formUnion(_ other: AlbumPair) {
            if let album = other.first { insert(album) }
            if let album = other.second { insert(album) }
        }

        func containsOther(than album: Int) -> Bool {
            (first != nil && first != album) || (second != nil && second != album)
        }
    }

    /// 艺人文件夹:文件夹名就是艺人名(忽略大小写、全半角、空白与标点)。
    /// 每张专辑的文件夹要么就是它(歌直接放在艺人文件夹里),要么是它的子文件夹;
    /// 对不上就不写,免得写进「音乐」这类总目录。
    ///
    /// `rootFolderName`: 音乐源本身就是一个文件夹、在 `/` 下展开时(Mac 和 iPhone 上选的
    /// 本地文件夹)那个文件夹自己的名字。选的就是艺人文件夹时,专辑文件夹的上一级是 `/`,
    /// 拿它的名字来比,`artist.nfo` 写在 `/` 下。
    public static func artistFolder(
        albumFolders: [String],
        artistName: String,
        rootFolderName: String? = nil
    ) -> String? {
        let artistKey = SongDiscoveryMatching.key(artistName)
        guard !artistKey.isEmpty, !albumFolders.isEmpty else { return nil }
        func matches(_ folder: String) -> Bool {
            if folder == "/" {
                guard let rootFolderName else { return false }
                return SongDiscoveryMatching.key(rootFolderName) == artistKey
            }
            return isUsableFolder(folder) && SongDiscoveryMatching.key(lastComponent(folder)) == artistKey
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

// MARK: - 评分、评论与红心写进 album.nfo

/// 一个专辑文件夹里的评分、评论与红心,存在 album.nfo 里 Primuse 自己的 `<primuse>` 那一段
/// (Kodi、Jellyfin、Emby 读 nfo 时跳过不认识的元素)。每首按专辑文件夹里的相对路径和 CUE 轨号认,
/// 不按曲库 id:删源重加、重装、整个文件夹挪地方之后照样对得上。
public struct LibraryFolderMarks: Equatable, Sendable {
    /// 一首歌或整张专辑的标记。每一项都带修改时间,清空也记时间,别的设备不会把它复活。
    public struct Mark: Equatable, Sendable {
        public var rating: Int?
        public var ratingModifiedAt: Date?
        /// nil 是没记;空串是明确清空(配合 `commentModifiedAt`)。
        public var comment: String?
        public var commentModifiedAt: Date?
        public var liked: Bool?
        public var likedModifiedAt: Date?

        public init(
            rating: Int? = nil,
            ratingModifiedAt: Date? = nil,
            comment: String? = nil,
            commentModifiedAt: Date? = nil,
            liked: Bool? = nil,
            likedModifiedAt: Date? = nil
        ) {
            self.rating = rating
            self.ratingModifiedAt = ratingModifiedAt
            self.comment = comment
            self.commentModifiedAt = commentModifiedAt
            self.liked = liked
            self.likedModifiedAt = likedModifiedAt
        }

        /// 什么都没记(连清空的时间也没有)。
        public var isEmpty: Bool {
            rating == nil && ratingModifiedAt == nil && comment == nil && commentModifiedAt == nil
                && liked == nil && likedModifiedAt == nil
        }

        /// 去掉评论(评论开关关着时写文件前用)。
        public var withoutComment: Mark {
            var mark = self
            mark.comment = nil
            mark.commentModifiedAt = nil
            return mark
        }
    }

    public struct Key: Hashable, Sendable {
        /// 专辑文件夹里的相对路径,如 `Album.wav`、`CD2/03 Song.flac`。
        public var file: String
        /// CUE 分轨的轨号;普通一首一个文件时为 nil。
        public var cueTrack: Int?

        public init(file: String, cueTrack: Int? = nil) {
            self.file = file
            self.cueTrack = cueTrack
        }
    }

    public struct Track: Equatable, Sendable {
        public var key: Key
        /// 写的时候的曲名与时长(秒),只用来核对是不是同一首。
        public var title: String?
        public var duration: Int?
        public var mark: Mark

        public init(key: Key, title: String? = nil, duration: Int? = nil, mark: Mark) {
            self.key = key
            self.title = title
            self.duration = duration
            self.mark = mark
        }
    }

    public var album: Mark?
    public var tracks: [Track]

    public init(album: Mark? = nil, tracks: [Track] = []) {
        self.album = album
        self.tracks = tracks
    }

    public var isEmpty: Bool { (album?.isEmpty ?? true) && tracks.allSatisfy(\.mark.isEmpty) }

    public var withoutComments: LibraryFolderMarks {
        LibraryFolderMarks(
            album: album?.withoutComment,
            tracks: tracks.map { track in
                var stripped = track
                stripped.mark = track.mark.withoutComment
                return stripped
            }
        )
    }

    /// 这首歌在文件里的那一条。路径先按原样比,对不上再不分大小写(SMB 不分大小写);
    /// 两边都有时长且差得多,说明文件被换成了别的录音,不认。
    public func track(for key: Key, duration: TimeInterval) -> Track? {
        let candidates = tracks.filter { $0.key.cueTrack == key.cueTrack }
        let match = candidates.first { $0.key.file == key.file }
            ?? candidates.first { $0.key.file.caseInsensitiveCompare(key.file) == .orderedSame }
        guard let match else { return nil }
        if let recorded = match.duration, recorded > 0, duration > 0,
           abs(Double(recorded) - duration) > LibraryFolderMarksPolicy.durationTolerance {
            return nil
        }
        return match
    }
}

/// 开关、相对路径与合并规则。
public enum LibraryFolderMarksPolicy {
    /// 评分和红心写进 album.nfo。默认开。
    public static let writeEnabledKey = "primuse.sidecar.marksWriteEnabled"
    /// 评论也一起写。默认开;评分和红心不写时它也不写。
    public static let commentsWriteEnabledKey = "primuse.sidecar.marksCommentsWriteEnabled"
    /// 时长差过这么多秒就当是换了文件。
    public static let durationTolerance: TimeInterval = 10

    /// 路径按「/」分层、专辑文件夹认得出来的文件类音乐源。按 id 寻址的网盘、媒体服务器与服务端曲库、
    /// 路径整段编码过的 NFS 都不在此列。
    public static func supports(_ type: MusicSourceType) -> Bool {
        type.libraryFolderPathSemantics == .hierarchical && type != .nfs
    }

    public static func writesMarks(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: writeEnabledKey) == nil ? true : defaults.bool(forKey: writeEnabledKey)
    }

    public static func writesComments(defaults: UserDefaults = .standard) -> Bool {
        guard writesMarks(defaults: defaults) else { return false }
        return defaults.object(forKey: commentsWriteEnabledKey) == nil
            ? true : defaults.bool(forKey: commentsWriteEnabledKey)
    }

    /// 文件在专辑文件夹里的相对路径;不在这个文件夹(含子文件夹)里时为 nil。
    public static func relativePath(of filePath: String, inFolder folder: String) -> String? {
        let prefix = folder == "/" ? "/" : (folder.hasSuffix("/") ? folder : folder + "/")
        guard filePath.hasPrefix(prefix), filePath.count > prefix.count else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    /// 文件里的与本机的按项合并:每一项取修改时间新的那边;都没有时间时本机有值就用本机的。
    /// 本机没记的项不会抹掉文件里的(重装后先打了一首分,不能把整张专辑的记录冲掉)。
    public static func merged(file: LibraryFolderMarks?, local: LibraryFolderMarks) -> LibraryFolderMarks {
        let fileMarks = file ?? LibraryFolderMarks()
        var tracks: [LibraryFolderMarks.Track] = []
        var localByKey: [LibraryFolderMarks.Key: LibraryFolderMarks.Track] = [:]
        for track in local.tracks { localByKey[track.key] = track }
        var seen = Set<LibraryFolderMarks.Key>()
        for track in fileMarks.tracks where seen.insert(track.key).inserted {
            guard let localTrack = localByKey[track.key] else {
                if !track.mark.isEmpty { tracks.append(track) }
                continue
            }
            let mark = merged(file: track.mark, local: localTrack.mark)
            guard !mark.isEmpty else { continue }
            tracks.append(LibraryFolderMarks.Track(
                key: track.key,
                title: localTrack.title ?? track.title,
                duration: localTrack.duration ?? track.duration,
                mark: mark
            ))
        }
        let added = local.tracks
            .filter { !seen.contains($0.key) && !$0.mark.isEmpty }
            .sorted { ($0.key.file, $0.key.cueTrack ?? 0) < ($1.key.file, $1.key.cueTrack ?? 0) }
        tracks += added
        let album: LibraryFolderMarks.Mark? = switch (fileMarks.album, local.album) {
        case (nil, nil): nil
        case (let file?, nil): file
        case (nil, let local?): local
        case (let file?, let local?): merged(file: file, local: local)
        }
        return LibraryFolderMarks(album: album?.isEmpty == true ? nil : album, tracks: tracks)
    }

    static func merged(file: LibraryFolderMarks.Mark, local: LibraryFolderMarks.Mark) -> LibraryFolderMarks.Mark {
        func pick<Value>(
            _ fileValue: Value?, _ fileDate: Date?, _ localValue: Value?, _ localDate: Date?
        ) -> (Value?, Date?) {
            switch (fileDate, localDate) {
            case let (fileDate?, localDate?):
                return localDate >= fileDate ? (localValue, localDate) : (fileValue, fileDate)
            case (nil, .some): return (localValue, localDate)
            case (.some, nil): return localValue != nil && fileValue == nil ? (localValue, nil) : (fileValue, fileDate)
            case (nil, nil): return (localValue ?? fileValue, nil)
            }
        }
        let rating = pick(file.rating, file.ratingModifiedAt, local.rating, local.ratingModifiedAt)
        let comment = pick(file.comment, file.commentModifiedAt, local.comment, local.commentModifiedAt)
        let liked = pick(file.liked, file.likedModifiedAt, local.liked, local.likedModifiedAt)
        return LibraryFolderMarks.Mark(
            rating: rating.0, ratingModifiedAt: rating.1,
            comment: comment.0, commentModifiedAt: comment.1,
            liked: liked.0, likedModifiedAt: liked.1
        )
    }

    /// 读回时这一项要不要盖过本机:文件里的较新,或本机没有这一项。没有时间的文件值只补本机的空缺。
    public static func fileWins(fileDate: Date?, localDate: Date?, localHasValue: Bool) -> Bool {
        switch (fileDate, localDate) {
        case let (fileDate?, localDate?): return fileDate > localDate
        case (.some, nil): return true
        case (nil, _): return !localHasValue && localDate == nil
        }
    }
}

/// 各专辑文件夹上次读回 album.nfo 时的签名(源 id|文件夹 → 签名),签名没变就不再去读。
/// 存在缓存目录里的一个文件:丢了只是重读一遍;放 UserDefaults 会随曲库长大,tvOS 上还有容量上限。
public enum LibraryFolderMarksSignatures {
    public static func key(sourceID: String, folder: String) -> String { sourceID + "|" + folder }

    /// 缓存目录下的 `Primuse/folder-marks-signatures.json`。
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("folder-marks-signatures.json")
    }

    public static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return entries
    }

    /// 记下这一轮读过的文件夹,并删掉这个源里已经不是专辑文件夹的旧记录。读、改、写一次做完,
    /// 调用方都在主线程上,两个源的读回不会互相盖掉。
    public static func update(
        at url: URL,
        sourceID: String,
        currentFolders: Set<String>,
        setting updates: [String: String]
    ) {
        var entries = load(from: url)
        let before = entries
        let prefix = sourceID + "|"
        for key in entries.keys where key.hasPrefix(prefix) {
            if !currentFolders.contains(String(key.dropFirst(prefix.count))) { entries[key] = nil }
        }
        entries.merge(updates) { _, new in new }
        guard entries != before else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            // 写不了就下次再读一遍,不影响已经读回的标记。
        }
    }
}

/// album.nfo 里 `<primuse version="1">` 那一段的读写。简介(`<review>`、`<style>`)和别的软件写的内容不动。
public enum LibraryFolderMarksNFO {
    static let elementName = "primuse"
    static let version = "1"

    /// 读出那一段;不是专辑 nfo、或没有这一段时为 nil。
    public static func read(_ text: String) -> LibraryFolderMarks? {
        guard let root = XMLTree.parse(text), root.name.lowercased() == "album",
              let block = root.firstChild(named: elementName) else { return nil }
        var marks = LibraryFolderMarks()
        if let album = block.firstChild(named: "albummark") {
            let mark = mark(from: album)
            marks.album = mark.isEmpty ? nil : mark
        }
        for element in block.children(named: "track") {
            guard let file = attribute("file", of: element), !file.isEmpty else { continue }
            let track = LibraryFolderMarks.Track(
                key: LibraryFolderMarks.Key(file: file, cueTrack: attribute("cue", of: element).flatMap { Int($0) }),
                title: attribute("title", of: element),
                duration: attribute("duration", of: element).flatMap { Int($0) },
                mark: mark(from: element)
            )
            guard !track.mark.isEmpty else { continue }
            marks.tracks.append(track)
        }
        return marks
    }

    /// 把这一段写进已有的 album.nfo(其余原样保留)或新建一份。已有文件不是专辑 nfo 时返回 nil,
    /// 不去改别人的文件;标记全空、文件里也没有这一段时原样交回(没东西可写)。
    public static func updatedDocument(
        existing: String?,
        title: String,
        artist: String,
        marks: LibraryFolderMarks
    ) -> String? {
        let root: XMLTree.Element
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = XMLTree.parse(existing), parsed.name.lowercased() == "album" else { return nil }
            root = parsed
        } else {
            guard !marks.isEmpty else { return existing }
            root = XMLTree.Element(name: "album")
            if !title.isEmpty { root.append(XMLTree.Element(name: "title", text: title)) }
            if !artist.isEmpty { root.append(XMLTree.Element(name: "artist", text: artist)) }
        }
        let hadBlock = root.firstChild(named: elementName) != nil
        if marks.isEmpty {
            guard hadBlock else { return existing }
            root.removeChildren(named: elementName)
            return XMLTree.document(root)
        }
        let block = XMLTree.Element(name: elementName, attributes: [("version", version)])
        if let album = marks.album, !album.isEmpty {
            block.append(element(named: "albummark", attributes: [], mark: album))
        }
        for track in marks.tracks where !track.mark.isEmpty {
            var attributes: [(String, String)] = [("file", track.key.file)]
            if let cue = track.key.cueTrack { attributes.append(("cue", String(cue))) }
            if let title = track.title, !title.isEmpty { attributes.append(("title", title)) }
            if let duration = track.duration, duration > 0 { attributes.append(("duration", String(duration))) }
            block.append(element(named: "track", attributes: attributes, mark: track.mark))
        }
        if let index = root.index(ofFirstChildNamed: elementName) {
            root.removeChildren(named: elementName)
            root.insert([block], at: min(index, root.childCount))
        } else {
            root.append(block)
        }
        return XMLTree.document(root)
    }

    private static func element(
        named name: String,
        attributes: [(String, String)],
        mark: LibraryFolderMarks.Mark
    ) -> XMLTree.Element {
        var attributes = attributes
        if let rating = mark.rating { attributes.append(("rating", String(rating))) }
        if let date = mark.ratingModifiedAt { attributes.append(("ratingat", format(date))) }
        if let liked = mark.liked { attributes.append(("liked", liked ? "true" : "false")) }
        if let date = mark.likedModifiedAt { attributes.append(("likedat", format(date))) }
        if let date = mark.commentModifiedAt { attributes.append(("commentat", format(date))) }
        let element = XMLTree.Element(name: name, attributes: attributes)
        if let comment = mark.comment, !comment.isEmpty {
            element.append(XMLTree.Element(name: "comment", text: comment))
        }
        return element
    }

    private static func mark(from element: XMLTree.Element) -> LibraryFolderMarks.Mark {
        let commentDate = attribute("commentat", of: element).flatMap(parse)
        let commentText = element.firstChild(named: "comment")?.text
        return LibraryFolderMarks.Mark(
            rating: attribute("rating", of: element).flatMap { Int($0) }.flatMap { (1...5).contains($0) ? $0 : nil },
            ratingModifiedAt: attribute("ratingat", of: element).flatMap(parse),
            // 有清空时间、没有评论元素:明确清空了。
            comment: commentText ?? (commentDate == nil ? nil : ""),
            commentModifiedAt: commentDate,
            liked: attribute("liked", of: element).flatMap { value in
                switch value.lowercased() {
                case "true", "1", "yes": true
                case "false", "0", "no": false
                default: nil
                }
            },
            likedModifiedAt: attribute("likedat", of: element).flatMap(parse)
        )
    }

    private static func attribute(_ name: String, of element: XMLTree.Element) -> String? {
        element.attributes.first { $0.0.lowercased() == name }?.1
    }

    private static func format(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    private static func parse(_ text: String) -> Date? {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? style.parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
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
        // XML 1.0 不允许的字符(除制表、换行、回车外的控制字符,U+FFFE、U+FFFF)写进去整份文件就读不了,直接去掉。
        let allowed = text.unicodeScalars.allSatisfy(isAllowedInXML)
        let cleaned = allowed ? text : String(String.UnicodeScalarView(text.unicodeScalars.filter(isAllowedInXML)))
        var result = cleaned
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            result = result.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return result
    }

    private static func isAllowedInXML(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: true
        case 0x0..<0x20, 0xFFFE, 0xFFFF: false
        default: true
        }
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
