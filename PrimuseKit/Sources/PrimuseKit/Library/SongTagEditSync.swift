import Foundation

/// 手改标签里同步的字段。封面单独一类:它的值是一张图,要另外传。
public enum SongTagEditField: String, CaseIterable, Sendable {
    case title
    case artist
    case album
    case albumArtist
    case genre
    case year
    case trackNumber
    case discNumber
    case cover
}

/// 手改过的封面。
public enum SongTagEditCover: Hashable, Sendable {
    /// 去掉了封面。
    case removed
    /// 音乐源里的图片文件(同目录的 cover.jpg 之类),各设备上路径一样。
    case sourceFile(String)
    /// 一张存在本机缓存里的图。`original` 是缓存里那份的内容哈希,别的设备读到同一份
    /// 内嵌封面时内容一样,可以直接指过去;`portable` 是传到 iCloud 的那份(缩到
    /// 1200 像素以内的 JPEG)的内容哈希,只有用户亲手换的封面才传,其余为 nil。
    case image(original: String, portable: String?)
}

extension SongTagEditCover: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, path, original, portable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "removed":
            self = .removed
        case "sourceFile":
            self = .sourceFile(try container.decode(String.self, forKey: .path))
        case "image":
            self = .image(
                original: try container.decode(String.self, forKey: .original),
                portable: try container.decodeIfPresent(String.self, forKey: .portable)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown cover kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .removed:
            try container.encode("removed", forKey: .kind)
        case .sourceFile(let path):
            try container.encode("sourceFile", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .image(let original, let portable):
            try container.encode("image", forKey: .kind)
            try container.encode(original, forKey: .original)
            try container.encodeIfPresent(portable, forKey: .portable)
        }
    }
}

/// 一个字段改成了什么、什么时候改的。文字字段用 `text`,数字字段用 `number`,
/// 艺术家另带音乐源给的多位艺术家列表 `names`,封面用 `cover`。值为 nil 表示清空了。
public struct SongTagEditValue: Codable, Hashable, Sendable {
    public var text: String?
    public var number: Int?
    public var names: [String]?
    public var cover: SongTagEditCover?
    public var modifiedAt: TimeInterval

    public init(
        text: String? = nil,
        number: Int? = nil,
        names: [String]? = nil,
        cover: SongTagEditCover? = nil,
        modifiedAt: TimeInterval
    ) {
        self.text = text
        self.number = number
        self.names = names
        self.cover = cover
        self.modifiedAt = modifiedAt
    }

    /// 同一时刻改了同一个字段时用来定胜负,两台设备算出来一样。空值和空字符串、空列表
    /// 各有各的写法,值不同时键一定不同。
    fileprivate var tieBreakKey: String {
        let coverKey: String
        switch cover {
        case nil: coverKey = "-"
        case .removed: coverKey = "r"
        case .sourceFile(let path): coverKey = "s:\(path)"
        case .image(let original, let portable): coverKey = "i:\(original):\(portable.map { "p:" + $0 } ?? "-")"
        }
        let textKey = text.map { "t:" + $0 } ?? "-"
        let numberKey = number.map { "n:\($0)" } ?? "-"
        let namesKey = names.map { "l:" + $0.joined(separator: "\u{2}") } ?? "-"
        return [textKey, numberKey, namesKey, coverKey].joined(separator: "\u{1}")
    }

    fileprivate func sameValue(as other: SongTagEditValue) -> Bool {
        text == other.text && number == other.number && names == other.names && cover == other.cover
    }
}

/// 一首歌手改过的标签,在 iPhone、iPad、Mac 之间同步用。
///
/// 每个字段单独记修改时间:两台设备改了不同的字段,两边的改动都留下;同一个字段以后改的
/// 为准。「恢复文件标签」记成 `restoredAt`,在它之前改的字段一律作废,别的设备上留着的
/// 旧改动不会再同步回来;恢复之后再改的字段照常生效。
public struct SongTagEdit: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var songID: String
    /// 键是 `SongTagEditField.rawValue`。新版本多出来的字段原样保留、参与合并,只是不套用。
    public var fields: [String: SongTagEditValue]
    public var restoredAt: TimeInterval?

    public init(
        songID: String,
        fields: [String: SongTagEditValue] = [:],
        restoredAt: TimeInterval? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.songID = songID
        self.fields = fields
        self.restoredAt = restoredAt
    }

    public subscript(field: SongTagEditField) -> SongTagEditValue? {
        get { fields[field.rawValue] }
        set { fields[field.rawValue] = newValue }
    }

    public var hasActiveFields: Bool { !fields.isEmpty }

    /// 除封面以外还有生效的字段。只换了封面的记录不给这一行打「用户编辑」标记:本机只换
    /// 封面时本来就不打(批量刮削封面也是),标签照常跟着文件走。
    public var hasActiveTextFields: Bool {
        fields.keys.contains { $0 != SongTagEditField.cover.rawValue }
    }

    /// 最近一次改动的时刻,没有改动时为 nil。
    public var latestModification: TimeInterval? {
        fields.values.map(\.modifiedAt).max()
    }

    /// 这条记录的内容变没变的指纹:合并只会让各字段的时间变大、字段变多或被恢复清掉,
    /// 任何一种都会让它变。按字段名排好再拼,同样的内容在哪台设备上算都一样。用来记
    /// 「哪一版已经套用到这一行上了」。
    public var revisionStamp: String {
        let parts = fields.keys.sorted().map { key in "\(key)=\(fields[key]?.modifiedAt ?? 0)" }
        return parts.joined(separator: ",") + ";\(restoredAt ?? 0)"
    }
}

/// 手改标签怎么记、怎么合并、怎么套到别的设备的那一行上。
///
/// 本机手改时(行上的 `userMetadataEditedAt` 变了)比较改前改后,把变了的字段连同修改
/// 时间记下来;「恢复文件标签」清掉标记时记一笔 `restoredAt`。别的设备收到后逐字段取新的,
/// 套到自己那一行上并打上同样的标记,于是本机的重扫、补读照旧保留这些字段。
public enum SongTagEditPolicy {
    /// 不含封面的字段。
    public static let textFields: [SongTagEditField] = SongTagEditField.allCases.filter { $0 != .cover }

    /// 这一行上某个字段现在的值(封面除外)。
    public static func value(
        of field: SongTagEditField,
        in song: Song,
        modifiedAt: TimeInterval
    ) -> SongTagEditValue? {
        switch field {
        case .title: return SongTagEditValue(text: song.title, modifiedAt: modifiedAt)
        case .artist:
            return SongTagEditValue(text: song.artistName, names: song.sourceArtistNames, modifiedAt: modifiedAt)
        case .album: return SongTagEditValue(text: song.albumTitle, modifiedAt: modifiedAt)
        case .albumArtist: return SongTagEditValue(text: song.albumArtistName, modifiedAt: modifiedAt)
        case .genre: return SongTagEditValue(text: song.genre, modifiedAt: modifiedAt)
        case .year: return SongTagEditValue(number: song.year, modifiedAt: modifiedAt)
        case .trackNumber: return SongTagEditValue(number: song.trackNumber, modifiedAt: modifiedAt)
        case .discNumber: return SongTagEditValue(number: song.discNumber, modifiedAt: modifiedAt)
        case .cover: return nil
        }
    }

    /// 改前改后哪些文字、数字字段变了。
    public static func changedTextFields(from previous: Song, to updated: Song) -> [SongTagEditField] {
        textFields.filter { field in
            guard let before = value(of: field, in: previous, modifiedAt: 0),
                  let after = value(of: field, in: updated, modifiedAt: 0) else { return false }
            return !before.sameValue(as: after)
        }
    }

    /// 封面引用指向音乐源里的文件(带目录),而不是本机缓存里按歌曲算出来的文件名。
    public static func isSourceFileReference(_ reference: String) -> Bool {
        reference.contains("/")
    }

    /// 引用本身的变化就能说清的封面改动:去掉了封面、换成了音乐源里的另一张图。换成缓存里
    /// 的一张图要读图算哈希,由调用方另外记;缓存文件名按歌曲算,换图时名字常常不变。
    public static func referenceCoverChange(from previous: Song, to updated: Song) -> SongTagEditCover? {
        guard previous.coverArtFileName != updated.coverArtFileName else { return nil }
        guard let reference = updated.coverArtFileName, !reference.isEmpty else { return .removed }
        return isSourceFileReference(reference) ? .sourceFile(reference) : nil
    }

    /// 本机这次改动用的时间:不早于改动本身,也一定晚于这首歌已经记下的所有改动与恢复,
    /// 所以本机后改的总能盖过之前的(哪怕设备时钟往回调过)。
    public static func editClock(existing: SongTagEdit?, at date: Date) -> TimeInterval {
        var clock = date.timeIntervalSince1970
        if let latest = existing?.latestModification { clock = max(clock, latest.nextUp) }
        if let restoredAt = existing?.restoredAt { clock = max(clock, restoredAt.nextUp) }
        return clock
    }

    /// 本机一次手改:把变了的文字字段记到 `clock`。没有变的字段时返回原记录(可能为 nil)。
    public static func recordingEdit(
        previous: Song,
        updated: Song,
        existing: SongTagEdit?,
        clock: TimeInterval
    ) -> SongTagEdit? {
        let changed = changedTextFields(from: previous, to: updated)
        guard !changed.isEmpty else { return existing }
        var edit = existing ?? SongTagEdit(songID: updated.id)
        for field in changed {
            edit[field] = value(of: field, in: updated, modifiedAt: clock)
        }
        return edit
    }

    /// 记下一次封面改动。比这首歌已有的封面改动或恢复早的不记。
    public static func recordingCover(
        _ cover: SongTagEditCover,
        songID: String,
        existing: SongTagEdit?,
        clock: TimeInterval
    ) -> SongTagEdit? {
        if let restoredAt = existing?.restoredAt, clock <= restoredAt { return existing }
        if let current = existing?[.cover], current.modifiedAt > clock { return existing }
        var edit = existing ?? SongTagEdit(songID: songID)
        edit[.cover] = SongTagEditValue(cover: cover, modifiedAt: clock)
        return edit
    }

    /// 「恢复文件标签」:之前的改动全部作废。
    public static func restoring(existing: SongTagEdit?, songID: String, at date: Date) -> SongTagEdit {
        var edit = existing ?? SongTagEdit(songID: songID)
        edit.restoredAt = editClock(existing: existing, at: date)
        edit.fields = [:]
        return edit
    }

    /// 这个功能上线之前就手改过的行:当时没记哪些字段改过,只能整行按改动时间记下来。
    /// 空着的字段不记,标题、艺术家还是从文件名拆出来的也不记 —— 那多半是改的时候这首歌
    /// 还没读过标签,不是用户填的值,记下来会把别的设备读好的标签盖掉。封面由调用方给(缓存里的图只记内容
    /// 哈希、不上传);没有封面时不记「去掉了封面」,说不清那是用户去掉的还是本来就没有。
    public static func legacyEdit(for song: Song, cover: SongTagEditCover?) -> SongTagEdit? {
        guard let marker = song.userMetadataEditedAt else { return nil }
        let clock = marker.timeIntervalSince1970
        let fileStem = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let fileNameTitles: Set<String> = [fileStem, MediaMetadataTextRepair.fileNameTitle(from: song.filePath)]
            .compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        let fileNameArtist = MediaMetadataTextRepair.fileNameArtist(from: song.filePath)
        var edit = SongTagEdit(songID: song.id)
        for field in textFields {
            guard let value = value(of: field, in: song, modifiedAt: clock),
                  value.text?.isEmpty == false || value.number != nil else { continue }
            if field == .title, let text = value.text, fileNameTitles.contains(text) { continue }
            if field == .artist, let fileNameArtist, value.text == fileNameArtist { continue }
            edit[field] = value
        }
        if let cover {
            edit[.cover] = SongTagEditValue(cover: cover, modifiedAt: clock)
        }
        return edit
    }

    /// 两份记录合并:逐字段取改得晚的,同一时刻取值排在后面的那份(两台设备算出来一样);
    /// 恢复时刻取晚的,早于它的字段丢掉。顺序无关、重复合并结果不变。
    public static func merged(_ lhs: SongTagEdit, _ rhs: SongTagEdit) -> SongTagEdit {
        var result = lhs
        result.schemaVersion = max(lhs.schemaVersion, rhs.schemaVersion)
        switch (lhs.restoredAt, rhs.restoredAt) {
        case let (left?, right?): result.restoredAt = max(left, right)
        case let (left, right): result.restoredAt = left ?? right
        }
        var fields: [String: SongTagEditValue] = [:]
        for key in Set(lhs.fields.keys).union(rhs.fields.keys) {
            let winner: SongTagEditValue
            switch (lhs.fields[key], rhs.fields[key]) {
            case let (left?, right?):
                if left.modifiedAt != right.modifiedAt {
                    winner = left.modifiedAt > right.modifiedAt ? left : right
                } else {
                    winner = left.tieBreakKey >= right.tieBreakKey ? left : right
                }
            case let (left?, nil): winner = left
            case let (nil, right?): winner = right
            case (nil, nil): continue
            }
            fields[key] = winner
        }
        result.fields = fields
        return normalized(result)
    }

    /// 去掉早于恢复时刻的字段。
    public static func normalized(_ edit: SongTagEdit) -> SongTagEdit {
        guard let restoredAt = edit.restoredAt else { return edit }
        var result = edit
        result.fields = edit.fields.filter { $0.value.modifiedAt > restoredAt }
        return result
    }

    /// 把记录里的文字、数字字段套到这一行上,有这类字段时打上「用户编辑」标记(封面另由调用方
    /// 处理,要读写缓存文件)。改了的文字把对应的拼音清掉,交给曲库重算。
    public static func applyingTextFields(_ edit: SongTagEdit, to song: Song) -> Song {
        var result = song
        for field in textFields {
            guard let value = edit[field] else { continue }
            switch field {
            case .title:
                if let text = value.text, !text.isEmpty, text != result.title {
                    result.title = text
                    result.titlePinyin = nil
                }
            case .artist:
                if result.artistName != value.text { result.artistPinyin = nil }
                result.artistName = value.text
                result.sourceArtistNames = value.names
            case .album:
                if result.albumTitle != value.text { result.albumPinyin = nil }
                result.albumTitle = value.text
            case .albumArtist: result.albumArtistName = value.text
            case .genre: result.genre = value.text
            case .year: result.year = value.number
            case .trackNumber: result.trackNumber = value.number
            case .discNumber: result.discNumber = value.number
            case .cover: break
            }
        }
        if edit.hasActiveTextFields, let latest = edit.latestModification {
            let stamp = Date(timeIntervalSince1970: latest)
            if result.userMetadataEditedAt.map({ $0 < stamp }) ?? true {
                result.userMetadataEditedAt = stamp
            }
        }
        return result
    }

    /// 这一行的手改要按恢复记录撤掉:记录里已经没有生效的字段,而行上的标记不晚于恢复时刻。
    /// 标记晚于恢复时刻的是恢复之后本机又改的,不撤。
    public static func needsRestore(_ edit: SongTagEdit, song: Song) -> Bool {
        guard !edit.hasActiveFields,
              let restoredAt = edit.restoredAt,
              let marker = song.userMetadataEditedAt else { return false }
        return marker.timeIntervalSince1970 <= restoredAt
    }
}

/// CloudKit 记录名只能用 ASCII、最长 255 个字符。专辑 id、歌曲 id 本来就是十六进制,
/// 流派 id 却是折叠后的流派名(中文等)。安全的键原样用,其余换成固定长度的哈希,
/// 记录里另带原来的键,收到时据此核对。
public enum CloudRecordNameEncoding {
    public static let maximumPlainLength = 200

    public static func recordName(for key: String) -> String {
        if isPlain(key) { return key }
        return "~" + hashHex(key)
    }

    public static func isPlain(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= maximumPlainLength, !key.hasPrefix("~"), !key.hasPrefix("_") else {
            return false
        }
        return key.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 58 || byte == 95
        }
    }

    /// 两路不同初值的 64 位 FNV-1a 拼成 32 位十六进制;只用来起名字,不涉及安全。
    static func hashHex(_ key: String) -> String {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x84222325_cbf29ce4
        for byte in key.utf8 {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            second = (second ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx%016llx", first, second)
    }
}
