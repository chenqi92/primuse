import Foundation
import PrimuseKit

enum TagMetadataWritebackField: String, CaseIterable, Sendable, Hashable {
    case title
    case artist
    case albumArtist
    case album
    case genre
    case year
    case trackNumber
    case discNumber
    case cover

    var localizedName: String {
        switch self {
        case .title: return String(localized: "tag_editor_title")
        case .albumArtist: return String(localized: "album_metadata_album_artist")
        case .artist: return String(localized: "tag_editor_artist")
        case .album: return String(localized: "tag_editor_album")
        case .genre: return String(localized: "tag_editor_genre")
        case .year: return String(localized: "tag_editor_year")
        case .trackNumber: return String(localized: "tag_editor_track")
        case .discNumber: return String(localized: "tag_editor_disc")
        case .cover: return String(localized: "tag_editor_cover_section")
        }
    }

    static func changedFields(
        from original: Song,
        to updated: Song,
        includesCover: Bool
    ) -> Set<Self> {
        var fields: Set<Self> = []
        if original.title != updated.title { fields.insert(.title) }
        if original.artistName != updated.artistName || original.sourceArtistNames != updated.sourceArtistNames { fields.insert(.artist) }
        if original.albumArtistName != updated.albumArtistName || original.sourceAlbumArtistNames != updated.sourceAlbumArtistNames {
            fields.insert(.albumArtist)
        }
        if original.albumTitle != updated.albumTitle { fields.insert(.album) }
        if original.genre != updated.genre { fields.insert(.genre) }
        if original.year != updated.year { fields.insert(.year) }
        if original.trackNumber != updated.trackNumber { fields.insert(.trackNumber) }
        if original.discNumber != updated.discNumber { fields.insert(.discNumber) }
        if includesCover { fields.insert(.cover) }
        return fields
    }

    static let metadataFields: Set<Self> = [
        .title,
        .artist,
        .album,
        .genre,
        .year,
        .trackNumber,
        .discNumber,
    ]

    /// 文字字段在资料库里的值,冲突比较和显示用。封面没有文字值。
    func value(in song: Song) -> String? {
        switch self {
        case .title: return song.title
        case .artist: return song.artistName
        case .albumArtist: return song.albumArtistName
        case .album: return song.albumTitle
        case .genre: return song.genre
        case .year: return song.year.map(String.init)
        case .trackNumber: return song.trackNumber.map(String.init)
        case .discNumber: return song.discNumber.map(String.init)
        case .cover: return nil
        }
    }

    /// 同一个字段在音频文件里现在的值。
    func value(in tags: EmbeddedMetadataVerification) -> String? {
        switch self {
        case .title: return tags.title
        case .artist: return tags.artist
        case .albumArtist: return tags.albumArtist
        case .album: return tags.albumTitle
        case .genre: return tags.genre
        case .year: return tags.year.map(String.init)
        case .trackNumber: return tags.trackNumber.map(String.init)
        case .discNumber: return tags.discNumber.map(String.init)
        case .cover: return nil
        }
    }

    /// 文件里这一项的值,按资料库会显示的样子:文件没有标题时资料库用文件名代替,比较和
    /// 「用文件里的值」都按这个算,不会把「文件里是空的」当成别处改过,也不会选了空值却留下用户的值。
    func fileValue(in tags: EmbeddedMetadataVerification, for song: Song) -> String? {
        if self == .title, TagWriteConflictPolicy.normalized(tags.title) == nil {
            // 两行的文件路径一样,得到的名字也一样;不能退回到行里的标题,那可能就是用户改的值。
            return MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
                ?? ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return value(in: tags)
    }

    /// 文字字段(封面另算)。
    static let textFields: [Self] = allCases.filter { $0 != .cover }

    /// 别处改了、这次没改的字段:资料库两行都换成文件里的值。只换一边会被算成改动,把旧值写回文件。
    @discardableResult
    static func adoptChangesElsewhere(
        from tags: EmbeddedMetadataVerification,
        original: inout Song,
        updated: inout Song,
        userChanged: Set<Self>
    ) -> [Self] {
        var adopted: [Self] = []
        for field in textFields where !userChanged.contains(field) {
            // 文件里没有标题时资料库的标题可能来自别处(刮削、文件名),不拿文件名去盖它。
            if field == .title, TagWriteConflictPolicy.normalized(tags.title) == nil { continue }
            let now = TagWriteConflictPolicy.normalized(field.fileValue(in: tags, for: original))
            guard now != TagWriteConflictPolicy.normalized(field.value(in: original)) else { continue }
            field.apply(tags, to: &original)
            field.apply(tags, to: &updated)
            adopted.append(field)
        }
        return adopted
    }

    /// 把文件里的值放回资料库这一行(用户在冲突里选了「文件里现在的值」、别处改了这一项时)。
    func apply(_ tags: EmbeddedMetadataVerification, to song: inout Song) {
        switch self {
        case .title:
            if let title = fileValue(in: tags, for: song), !title.isEmpty { song.title = title }
        case .artist:
            if song.artistName != tags.artist { song.sourceArtistNames = nil }
            song.artistName = tags.artist
        case .albumArtist:
            if song.albumArtistName != tags.albumArtist { song.sourceAlbumArtistNames = nil }
            song.albumArtistName = tags.albumArtist
        case .album: song.albumTitle = tags.albumTitle
        case .genre: song.genre = tags.genre
        case .year: song.year = tags.year
        case .trackNumber: song.trackNumber = tags.trackNumber
        case .discNumber: song.discNumber = tags.discNumber
        case .cover: break
        }
    }

    /// 从另一行取这个字段的值(用户在冲突里选了「我的修改」)。
    func copy(from source: Song, to song: inout Song) {
        switch self {
        case .title: song.title = source.title
        case .artist:
            song.artistName = source.artistName
            song.sourceArtistNames = source.sourceArtistNames
        case .albumArtist:
            song.albumArtistName = source.albumArtistName
            song.sourceAlbumArtistNames = source.sourceAlbumArtistNames
        case .album: song.albumTitle = source.albumTitle
        case .genre: song.genre = source.genre
        case .year: song.year = source.year
        case .trackNumber: song.trackNumber = source.trackNumber
        case .discNumber: song.discNumber = source.discNumber
        case .cover: break
        }
    }
}

/// 标签保存撞上「文件在编辑期间被别处改过」,重读文件之后发现同一项两边都改了:
/// 把文件里现在的值和用户的修改摆出来,让用户选。
struct TagWriteConflict: Sendable {
    /// 资料库这一行,换成了文件现在的身份(大小、修改时间、版本)。再写一次时用它当原始行。
    let refreshedOriginal: Song
    /// 用户这次要写的那一行。
    let edited: Song
    /// 文件里现在的标签(含封面)。
    let fileTags: EmbeddedMetadataVerification
    /// 两边都改了的字段,按显示顺序;封面两边都换了时也在里面。
    let fields: [TagMetadataWritebackField]
    /// 用户这次换的封面(写进文件的那一份)。
    var editedCover: Data? = nil

    func fileValue(_ field: TagMetadataWritebackField) -> String? {
        field.fileValue(in: fileTags, for: refreshedOriginal)
    }
    func editedValue(_ field: TagMetadataWritebackField) -> String? { field.value(in: edited) }

    struct Resolution: Sendable {
        var original: Song
        var updated: Song
        /// 要写进文件的封面;选了「文件里现在的封面」或没换封面时是 nil。
        var coverData: Data?
        /// 选了文件里现在的封面:资料库的封面跟着换成这张。
        var adoptedFileCover: Data?
        /// 两行之间还有要写的东西(文字字段或封面)。
        var writesSomething: Bool {
            coverData != nil || SongUserMetadataPolicy.editableFieldsChanged(from: original, to: updated)
        }
    }

    /// 用户选完之后要写的两行:`keepsFileValue` 里的字段用文件里的值,其余用用户的修改。
    /// - 冲突的这几项,原始行换成文件现在的值,写回只改和文件不一样的字段。
    /// - 别处改了、用户没动的字段,两行都换成文件里的值,资料库跟上文件,也不会被当成改动写回旧值。
    /// - 用户编辑标记先回到编辑前的样子,由保存的地方按真正写了用户的值再打。
    func resolved(keepingFileValueFor keepsFileValue: Set<TagMetadataWritebackField>) -> Resolution {
        var original = refreshedOriginal
        var updated = edited
        updated.filePath = refreshedOriginal.filePath
        updated.fileSize = refreshedOriginal.fileSize
        updated.lastModified = refreshedOriginal.lastModified
        updated.revision = refreshedOriginal.revision
        updated.userMetadataEditedAt = refreshedOriginal.userMetadataEditedAt
        let userChanged = TagMetadataWritebackField.changedFields(from: refreshedOriginal, to: edited, includesCover: false)
        for field in fields where field != .cover {
            field.apply(fileTags, to: &original)
            if keepsFileValue.contains(field) {
                field.apply(fileTags, to: &updated)
            }
        }
        TagMetadataWritebackField.adoptChangesElsewhere(
            from: fileTags,
            original: &original,
            updated: &updated,
            userChanged: userChanged.union(fields)
        )
        let keepsFileCover = fields.contains(.cover) && keepsFileValue.contains(.cover)
        return Resolution(
            original: original,
            updated: updated,
            coverData: keepsFileCover ? nil : editedCover,
            adoptedFileCover: keepsFileCover ? fileTags.coverData : nil
        )
    }
}

/// 一首歌的音频文件和所在文件夹当前能不能写。只有本机文件探测得出;远端源由服务端在写的时候判断。
struct SaveLocationAccess: Sendable, Equatable {
    var audioFile: SaveLocationPolicy.Access = .unknown
    var folder: SaveLocationPolicy.Access = .unknown
    /// iCloud 云盘里这首歌还有没处理的冲突版本。
    var hasICloudConflict = false

    static let unknown = SaveLocationAccess()
}

/// 能探测文件和文件夹写入权限的连接器(本机文件夹、单独添加的文件)。
protocol SaveLocationProbing: Sendable {
    func saveLocationAccess(for path: String) async -> SaveLocationAccess
}

enum TagMetadataFieldWritebackDisposition: Sendable, Equatable {
    case unchanged
    case written
    case localOnly
    case unsupported(String)
    case failed(String)
}

struct TagMetadataFieldWritebackResult: Sendable, Equatable {
    let field: TagMetadataWritebackField
    let disposition: TagMetadataFieldWritebackDisposition
}

