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
