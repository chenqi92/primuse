import Foundation

/// 音乐源卡片点进去的「文件」页：哪些源能看文件、一层目录怎么分组排序、
/// 歌词与封面怎么挂到它旁边那首歌上、曲库里有几首在某个目录下。界面只管画。
public enum SourceFileBrowserPolicy {
    /// 卡片点进去是文件页的源。音乐服务器的曲库在服务器上、Apple Music 没有文件,
    /// 这两类进的是各自的概览页。
    public static func browsesFiles(_ type: MusicSourceType) -> Bool {
        switch type.category {
        case .nas, .protocol, .cloudDrive: return true
        case .local: return type == .local
        case .mediaServer, .streaming: return false
        }
    }

    /// 列目录拿到的一条。和连接器的 `RemoteFileItem` 一一对应,只留这里用得上的字段。
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let size: Int64
        public let modifiedDate: Date?

        public init(name: String, path: String, isDirectory: Bool, size: Int64, modifiedDate: Date?) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.size = size
            self.modifiedDate = modifiedDate
        }
    }

    public struct AudioFile: Equatable, Sendable {
        public let entry: Entry
        /// 扩展名认出来的格式;`.m4b` 这类别名照 `AudioFormat.from(fileExtension:)` 归并。
        public let format: AudioFormat?
        /// 同名的歌词文件(`稻香.lrc`、`稻香.ttml`…),按读取优先级排。
        public let lyrics: [Entry]
        /// 同名的封面(`稻香.jpg`、`稻香-cover.png`)。
        public let cover: Entry?
    }

    public struct Listing: Equatable, Sendable {
        public var folders: [Entry] = []
        public var audioFiles: [AudioFile] = []
        /// 既不是目录、也不是歌、也没挂到哪首歌旁边的文件(文件夹封面、文本、视频…)。
        public var otherFileCount = 0

        public init() {}
    }

    /// NAS 与 Windows 共享里的系统目录,用户不会到这里面找歌。
    private static let hiddenFolderNames: Set<String> = [
        "@eadir", "#recycle", "#snapshot", "@recycle", "$recycle.bin",
        "system volume information", "lost+found", "@tmp",
    ]

    public static func isHidden(_ entry: Entry) -> Bool {
        if entry.name.hasPrefix(".") { return true }
        return entry.isDirectory && hiddenFolderNames.contains(entry.name.lowercased())
    }

    public static func isAudioFileName(_ name: String) -> Bool {
        PrimuseConstants.supportedAudioExtensions.contains(fileExtension(of: name))
    }

    /// 把一层目录分成文件夹、歌、其他文件。文件夹与歌都按名字自然排序(「2」在「10」前面)。
    public static func listing(of entries: [Entry]) -> Listing {
        var listing = Listing()
        var audio: [Entry] = []
        var others: [Entry] = []
        for entry in entries where !isHidden(entry) {
            if entry.isDirectory {
                listing.folders.append(entry)
            } else if isAudioFileName(entry.name) {
                audio.append(entry)
            } else {
                others.append(entry)
            }
        }
        listing.folders.sort(by: nameOrder)
        audio.sort(by: nameOrder)

        // 一个歌词/封面只挂给同名的那一首;两首同名不同格式(稻香.flac、稻香.mp3)都显示它。
        let stems = Dictionary(grouping: audio.indices) { stemKey(audio[$0].name) }
        var lyricsByAudio: [Int: [Entry]] = [:]
        var coverByAudio: [Int: Entry] = [:]
        var attached = Set<Int>()
        let lyricRank = Dictionary(
            PrimuseConstants.readableLyricsExtensions.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (index, entry) in others.enumerated() {
            let ext = fileExtension(of: entry.name)
            let stem = stemKey(entry.name)
            if lyricRank[ext] != nil, let owners = stems[stem] {
                for owner in owners { lyricsByAudio[owner, default: []].append(entry) }
                attached.insert(index)
            } else if PrimuseConstants.supportedCoverExtensions.contains(ext) {
                let ownerStem = stem.hasSuffix("-cover") ? String(stem.dropLast("-cover".count)) : stem
                guard let owners = stems[ownerStem] else { continue }
                for owner in owners where coverByAudio[owner] == nil { coverByAudio[owner] = entry }
                attached.insert(index)
            }
        }
        listing.audioFiles = audio.indices.map { index in
            let entry = audio[index]
            let lyrics = (lyricsByAudio[index] ?? []).sorted {
                (lyricRank[fileExtension(of: $0.name)] ?? .max) < (lyricRank[fileExtension(of: $1.name)] ?? .max)
            }
            return AudioFile(
                entry: entry,
                format: AudioFormat.from(fileExtension: fileExtension(of: entry.name)),
                lyrics: lyrics,
                cover: coverByAudio[index]
            )
        }
        listing.otherFileCount = others.count - attached.count
        return listing
    }

    /// 改名框里预填的名字:去掉扩展名。
    public static func stem(of fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    private static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private static func stemKey(_ name: String) -> String {
        stem(of: name).precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func nameOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }

    // MARK: - 曲库里有几首

    /// 一个源在曲库里的歌,按目录数。只对路径里带目录的源有意义 —— 按文件 ID
    /// 寻址的网盘、UPnP 的条目路径里没有目录,只能按整条路径对上单个文件。
    public struct LibraryIndex: Equatable, Sendable {
        private var songsByFile: [String: Int] = [:]
        private var songsUnderFolder: [String: Int] = [:]

        public init() {}

        /// `songPaths` 是这个源每首歌的 `filePath`(CUE 分轨一首一条,同一个文件会出现几次)。
        public init(songPaths: [String], countsFolders: Bool) {
            for path in songPaths {
                songsByFile[path, default: 0] += 1
                guard countsFolders else { continue }
                for folder in Self.enclosingFolders(of: path) {
                    songsUnderFolder[folder, default: 0] += 1
                }
            }
        }

        /// 这个文件在曲库里是几首歌(CUE 整轨可能是十几首),不在曲库里是 0。
        public func songCount(forFile path: String) -> Int {
            songsByFile[path] ?? 0
        }

        /// 这个目录里(含子目录)有几首已入库。
        public func songCount(inFolder path: String) -> Int {
            songsUnderFolder[Self.folderKey(path)] ?? 0
        }

        public var isEmpty: Bool { songsByFile.isEmpty }

        static func folderKey(_ path: String) -> String {
            var key = path
            while key.count > 1, key.hasSuffix("/") { key.removeLast() }
            return key.isEmpty ? "/" : key
        }

        /// `/音乐/华语/稻香.flac` → `/音乐/华语`、`/音乐`、`/`;
        /// S3 那种不带开头斜杠的 `Music/a.flac` → `Music`、`/`。
        static func enclosingFolders(of path: String) -> [String] {
            var folders: [String] = []
            var current = Substring(path)
            while let slash = current.lastIndex(of: "/") {
                current = current[..<slash]
                guard !current.isEmpty else { break }
                folders.append(String(current))
            }
            folders.append("/")
            return folders
        }
    }
}

/// 文件页里给目录改名之后,曲库路径与扫描索引怎么跟着搬。只认路径里带目录的源。
public enum SourceFolderRelocationPolicy {
    /// `path` 在 `old` 目录里(或就是它)时,换成 `new` 下面的同一位置;不在里面返回 nil。
    /// 只按整段目录名比较:`/音乐/华语` 不会匹配 `/音乐/华语经典`。
    public static func relocatedPath(_ path: String, from old: String, to new: String) -> String? {
        let oldBase = trimmedDirectory(old)
        let newBase = trimmedDirectory(new)
        if path == oldBase || path == oldBase + "/" { return newBase }
        let prefix = oldBase == "/" ? "/" : oldBase + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        return (newBase == "/" ? "/" : newBase + "/") + rest
    }

    /// 同一层里的新目录名。去掉首尾空白;空的、`.`、`..`、带 `/` 或超过 255 字节的都不行。
    public static func validatedFolderName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else { return nil }
        return name
    }

    /// 同一层里改名后的完整路径。
    public static func siblingPath(of path: String, named name: String) -> String {
        let trimmed = trimmedDirectory(path)
        let parent = (trimmed as NSString).deletingLastPathComponent
        if parent.isEmpty { return name }
        return (parent as NSString).appendingPathComponent(name)
    }

    /// 这个目录本身被勾成扫描目录,或者里面有被勾的。改它的名字等于改扫描范围,得回选目录页去做。
    public static func touchesScanRoots(
        _ path: String,
        selections: [String],
        sourceType: MusicSourceType
    ) -> Bool {
        selections.contains { SourceDirectorySelectionPolicy.covers(path, $0, for: sourceType) }
    }

    /// 把扫描索引里这棵子树搬到新路径:条目的路径、上级、键一起换,旧键记成别名,
    /// 下次扫描按原来的歌曲 ID 认回这些文件,不会当成删掉一批、又新增一批。返回改了几条。
    @discardableResult
    public static func relocate(_ state: inout SourceSyncState, from old: String, to new: String) -> Int {
        var moves: [(oldKey: String, newKey: String, item: SourceSyncIndexedItem)] = []
        for (key, item) in state.index {
            guard let newPath = relocatedPath(item.path, from: old, to: new) else { continue }
            var moved = item
            let newKey: String
            if key == "path:\(item.path.lowercased())" {
                newKey = "path:\(newPath.lowercased())"
            } else if key == item.path {
                newKey = newPath
            } else {
                newKey = key
            }
            if let parent = item.parentPath, let newParent = relocatedPath(parent, from: old, to: new) {
                moved.parentPath = newParent
            }
            if moved.displayName == (item.path as NSString).lastPathComponent {
                moved.displayName = (newPath as NSString).lastPathComponent
            }
            moved.path = newPath
            moved.stableKey = newKey
            if !moved.isDirectory { moved.sidecarFingerprint = nil }
            moves.append((key, newKey, moved))
        }
        for move in moves where move.oldKey != move.newKey {
            state.index.removeValue(forKey: move.oldKey)
        }
        for move in moves {
            state.index[move.newKey] = move.item
            guard move.oldKey != move.newKey else { continue }
            state.identityAliases[move.oldKey] = move.newKey
            state.missingStableKeys.removeValue(forKey: move.oldKey)
            state.missingStableKeys.removeValue(forKey: move.newKey)
        }
        state.pendingDirectories = state.pendingDirectories.map {
            relocatedPath($0, from: old, to: new) ?? $0
        }
        return moves.count
    }

    private static func trimmedDirectory(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }
}

/// 文件页里把一首歌移到另一个文件夹:同名的歌词、封面、视频跟着走,目标里已有同名的就不动。
public enum SourceFileMovePlan {
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String
    }

    public enum Failure: Error, Equatable, Sendable {
        /// 目标文件夹里已经有同名的文件。
        case collision(String)
        /// 原来那一层里找不到这首歌了。
        case missingFile
        /// 同一个文件夹里有 CUE:整轨文件和分轨对不上名字,不能单独挪。
        case cue
    }

    private static let sidecarExtensions: Set<String> = Set(PrimuseConstants.readableLyricsExtensions)
        .union(PrimuseConstants.supportedCoverExtensions)
        .union(["mp4", "mov", "m4v"])

    /// `sourceEntries` 是歌所在那一层,`destinationNames` 是目标文件夹里已有的名字。
    public static func moves(
        audioPath: String,
        sourceEntries: [SourceFileBrowserPolicy.Entry],
        destinationDirectory: String,
        destinationNames: [String]
    ) throws -> [Move] {
        guard let audio = sourceEntries.first(where: { $0.path == audioPath && !$0.isDirectory }) else {
            throw Failure.missingFile
        }
        guard !sourceEntries.contains(where: { !$0.isDirectory && ($0.name as NSString).pathExtension.lowercased() == "cue" }) else {
            throw Failure.cue
        }
        let stem = key(SourceFileBrowserPolicy.stem(of: audio.name))
        var moving = [audio]
        for entry in sourceEntries where !entry.isDirectory && entry.path != audio.path {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            guard sidecarExtensions.contains(ext) else { continue }
            let entryStem = key(SourceFileBrowserPolicy.stem(of: entry.name))
            if entryStem == stem || entryStem == stem + "-cover" || entryStem == stem + "-back" {
                moving.append(entry)
            }
        }
        let taken = Set(destinationNames.map(key))
        let base = destinationDirectory.hasSuffix("/") ? String(destinationDirectory.dropLast()) : destinationDirectory
        return try moving.map { entry in
            guard !taken.contains(key(entry.name)) else { throw Failure.collision(entry.name) }
            let target = base.isEmpty ? entry.name : (base == "/" ? "/" + entry.name : base + "/" + entry.name)
            return Move(from: entry.path, to: target)
        }
    }

    /// 能不能把目录 `folder` 挪进 `destination`:不能挪进它自己或它下面,挪回原处也没意义。
    public static func canMoveFolder(_ folder: String, into destination: String) -> Bool {
        let parent = (trimmed(folder) as NSString).deletingLastPathComponent
        guard SourceFolderRelocationPolicy.relocatedPath(destination, from: folder, to: folder) == nil else { return false }
        return trimmed(destination) != (parent.isEmpty ? "/" : parent)
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func trimmed(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }
}
