import Foundation
import PrimuseKit

// 歌曲页的排序选项与各维度的名字(从 `SongListView.swift` 搬出,内容不变)。

extension SongListView {
    enum SongSortOrder: String, CaseIterable, Sendable {
        case title, titleDescending
        case fileName, fileNameDescending
        case artist, artistDescending
        case album, albumDescending
        case dateAdded, dateAddedOldest
        case sourceDate, sourceDateOldest
        case format, formatDescending
        case duration, durationDescending
        case playCount, playCountDescending
        case serverPlayCount, serverPlayCountDescending
        case source, sourceDescending
        case year, yearDescending
        case bitRate, bitRateDescending
        case bitDepth, bitDepthDescending
        case downloaded, downloadedFirst

        var libraryOrder: LibrarySongSortOrder {
            switch self {
            case .title: return .title
            case .titleDescending: return .titleDescending
            case .fileName: return .fileName
            case .fileNameDescending: return .fileNameDescending
            case .artist: return .artist
            case .artistDescending: return .artistDescending
            case .album: return .album
            case .albumDescending: return .albumDescending
            case .dateAdded: return .dateAdded
            case .dateAddedOldest: return .dateAddedOldest
            case .sourceDate: return .sourceDate
            case .sourceDateOldest: return .sourceDateOldest
            case .format: return .format
            case .formatDescending: return .formatDescending
            case .duration: return .duration
            case .durationDescending: return .durationDescending
            case .playCount: return .playCount
            case .playCountDescending: return .playCountDescending
            case .serverPlayCount: return .serverPlayCount
            case .serverPlayCountDescending: return .serverPlayCountDescending
            case .source: return .source
            case .sourceDescending: return .sourceDescending
            case .year: return .year
            case .yearDescending: return .yearDescending
            case .bitRate: return .bitRate
            case .bitRateDescending: return .bitRateDescending
            case .bitDepth: return .bitDepth
            case .bitDepthDescending: return .bitDepthDescending
            case .downloaded: return .downloaded
            case .downloadedFirst: return .downloadedFirst
            }
        }

        init(libraryOrder: LibrarySongSortOrder) {
            switch libraryOrder {
            case .title: self = .title
            case .titleDescending: self = .titleDescending
            case .fileName: self = .fileName
            case .fileNameDescending: self = .fileNameDescending
            case .artist: self = .artist
            case .artistDescending: self = .artistDescending
            case .album: self = .album
            case .albumDescending: self = .albumDescending
            case .dateAdded: self = .dateAdded
            case .dateAddedOldest: self = .dateAddedOldest
            case .sourceDate: self = .sourceDate
            case .sourceDateOldest: self = .sourceDateOldest
            case .format: self = .format
            case .formatDescending: self = .formatDescending
            case .duration: self = .duration
            case .durationDescending: self = .durationDescending
            case .playCount: self = .playCount
            case .playCountDescending: self = .playCountDescending
            case .serverPlayCount: self = .serverPlayCount
            case .serverPlayCountDescending: self = .serverPlayCountDescending
            case .source: self = .source
            case .sourceDescending: self = .sourceDescending
            case .year: self = .year
            case .yearDescending: self = .yearDescending
            case .bitRate: self = .bitRate
            case .bitRateDescending: self = .bitRateDescending
            case .bitDepth: self = .bitDepth
            case .bitDepthDescending: self = .bitDepthDescending
            case .downloaded: self = .downloaded
            case .downloadedFirst: self = .downloadedFirst
            }
        }

        var criterion: LibrarySongSortCriterion { libraryOrder.criterion }

        var isAscending: Bool { libraryOrder.isAscending }

        var directionIcon: String { isAscending ? "arrow.up" : "arrow.down" }

        var directionLabel: String { String(localized: directionKey) }

        func selecting(_ criterion: LibrarySongSortCriterion) -> SongSortOrder {
            SongSortOrder(libraryOrder: libraryOrder.selecting(criterion))
        }

        var label: String {
            criterion.label
        }

        private var directionKey: String.LocalizationValue {
            isAscending ? "smart_sort_ascending" : "smart_sort_descending"
        }
    }
}

// 歌单详情页也要按同一套维度名给排序菜单打标签,所以这里不再是 private。
extension LibrarySongSortCriterion {
    var label: String {
        switch self {
        case .title: return String(localized: "sort_title")
        case .fileName: return String(localized: "sort_file_name")
        case .artist: return String(localized: "sort_artist")
        case .album: return String(localized: "sort_album")
        case .dateAdded: return String(localized: "sort_date_added")
        case .sourceDate: return String(localized: "sort_source_date")
        case .format: return String(localized: "sort_format")
        case .duration: return String(localized: "duration_label")
        case .playCount: return String(localized: "stats_play_count")
        case .serverPlayCount: return String(localized: "server_play_count_label")
        case .source: return String(localized: "source_label")
        case .year: return String(localized: "year_label")
        case .bitRate: return String(localized: "songs_column_bitrate")
        case .bitDepth: return String(localized: "bit_depth_label")
        case .downloaded: return String(localized: "filter_downloaded")
        }
    }

    /// Compact/mobile sort menus keep their established choices. Additional
    /// technical and device-state criteria are exposed by the macOS headers.
    #if os(macOS)
    static let menuCases: [LibrarySongSortCriterion] = [
        .title, .fileName, .artist, .album, .dateAdded, .sourceDate, .format,
    ]
    #else
    static let menuCases: [LibrarySongSortCriterion] = [
        .title, .artist, .album, .dateAdded, .sourceDate, .format,
    ]
    #endif
}
