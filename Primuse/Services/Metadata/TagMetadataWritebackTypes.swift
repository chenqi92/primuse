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
        if original.albumArtistName != updated.albumArtistName { fields.insert(.albumArtist) }
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

