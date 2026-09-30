#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

enum MacSongsColumn: String, CaseIterable, Hashable, Identifiable {
    case title, artist, album, format, duration, plays, sourcePlays, downloaded
    case source, year, rating, dateAdded, bitRate, bitDepth

    var id: String { rawValue }

    static let defaultVisible: Set<MacSongsColumn> = [
        .title, .artist, .album, .format, .duration, .plays, .sourcePlays,
        .downloaded, .source, .bitRate, .bitDepth,
    ]

    var title: String {
        switch self {
        case .title: String(localized: "sort_title")
        case .artist: String(localized: "artist_label")
        case .album: String(localized: "album_label")
        case .format: String(localized: "songs_column_format_sample_rate")
        case .duration: String(localized: "duration_label")
        case .plays: String(localized: "stats_play_count")
        case .sourcePlays: String(localized: "server_play_count_label")
        case .downloaded: String(localized: "filter_downloaded")
        case .source: String(localized: "source_label")
        case .year: String(localized: "year_label")
        case .rating: String(localized: "songs_column_rating")
        case .dateAdded: String(localized: "sort_date_added")
        case .bitRate: String(localized: "songs_column_bitrate")
        case .bitDepth: String(localized: "bit_depth_label")
        }
    }

    var sortCriterion: LibrarySongSortCriterion? {
        switch self {
        case .title: .title
        case .artist: .artist
        case .album: .album
        case .format: .format
        case .duration: .duration
        case .plays: .playCount
        case .sourcePlays: .serverPlayCount
        case .downloaded: .downloaded
        case .source: .source
        case .year: .year
        case .rating: nil
        case .dateAdded: .dateAdded
        case .bitRate: .bitRate
        case .bitDepth: .bitDepth
        }
    }

    var alignment: Alignment {
        switch self {
        case .title, .artist, .album, .format, .source: .leading
        case .downloaded: .center
        default: .trailing
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .title: 240
        case .artist: 170
        case .album: 210
        case .format: 110
        case .duration, .plays: 72
        case .sourcePlays, .source: 110
        case .downloaded: 88
        case .year, .rating: 60
        case .dateAdded: 100
        case .bitRate: 90
        case .bitDepth: 82
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .title: 120
        case .artist, .album: 90
        case .format: 96
        case .sourcePlays: 90
        case .downloaded: 76
        case .source: 72
        case .dateAdded: 84
        case .bitRate, .bitDepth: 70
        default: 54
        }
    }

    func clampedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), 520)
    }
}

@MainActor
@Observable
final class MacSongTableLayout {
    enum Scope {
        case library, playlist

        var keyPrefix: String {
            switch self {
            case .library: "library.macSongTable"
            case .playlist: "playlist.macSongTable"
            }
        }

        var defaultVisible: Set<MacSongsColumn> {
            switch self {
            case .library: MacSongsColumn.defaultVisible
            case .playlist: [.title, .artist, .album, .format, .duration, .plays, .source]
            }
        }
    }

    static let spacing: CGFloat = 12
    static let artworkWidth: CGFloat = 32
    static let horizontalPadding: CGFloat = 10

    var visibleColumns: Set<MacSongsColumn> {
        didSet { defaults.set(visibleColumns.map(\.rawValue).sorted(), forKey: key("visibleColumns")) }
    }
    var columnOrder: [MacSongsColumn] {
        didSet { defaults.set(columnOrder.map(\.rawValue), forKey: key("columnOrder")) }
    }
    var showsHeader: Bool {
        didSet { defaults.set(showsHeader, forKey: key("showsHeader")) }
    }
    private(set) var columnWidths: [MacSongsColumn: CGFloat]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scope: Scope

    init(scope: Scope, defaults: UserDefaults = .standard) {
        self.scope = scope
        self.defaults = defaults
        let prefix = scope.keyPrefix
        let storedVisible = defaults.stringArray(forKey: "\(prefix).visibleColumns.v1")
        visibleColumns = (storedVisible.map { Set($0.compactMap(MacSongsColumn.init(rawValue:))) }
            ?? scope.defaultVisible).union([.title])
        let storedOrder = defaults.stringArray(forKey: "\(prefix).columnOrder.v1") ?? []
        var seen: Set<MacSongsColumn> = []
        var order = storedOrder.compactMap(MacSongsColumn.init(rawValue:)).filter { seen.insert($0).inserted }
        order.append(contentsOf: MacSongsColumn.allCases.filter { seen.insert($0).inserted })
        columnOrder = order
        let storedWidths = defaults.dictionary(forKey: "\(prefix).columnWidths.v1") ?? [:]
        columnWidths = Dictionary(uniqueKeysWithValues: MacSongsColumn.allCases.map { column in
            let width = (storedWidths[column.rawValue] as? NSNumber).map { CGFloat(truncating: $0) }
                ?? column.defaultWidth
            return (column, column.clampedWidth(width))
        })
        showsHeader = defaults.object(forKey: "\(prefix).showsHeader.v1") as? Bool ?? true
    }

    var activeColumns: [MacSongsColumn] { columnOrder.filter(visibleColumns.contains) }

    func width(_ column: MacSongsColumn) -> CGFloat {
        column.clampedWidth(columnWidths[column] ?? column.defaultWidth)
    }

    func contentWidth(ordinalWidth: CGFloat) -> CGFloat {
        ordinalWidth + Self.artworkWidth + activeColumns.reduce(0) { $0 + width($1) }
            + CGFloat(activeColumns.count + 1) * Self.spacing
    }

    func toggle(_ column: MacSongsColumn) {
        guard column != .title else { return }
        if visibleColumns.contains(column) { visibleColumns.remove(column) }
        else { visibleColumns.insert(column) }
    }

    func resize(_ column: MacSongsColumn, to width: CGFloat) {
        columnWidths[column] = column.clampedWidth(width)
    }

    func saveWidths() {
        defaults.set(Dictionary(uniqueKeysWithValues: columnWidths.map { ($0.key.rawValue, Double($0.value)) }),
                     forKey: key("columnWidths"))
    }

    func move(_ column: MacSongsColumn, relativeTo target: MacSongsColumn, after: Bool) {
        guard column != target, let sourceIndex = columnOrder.firstIndex(of: column) else { return }
        var order = columnOrder
        order.remove(at: sourceIndex)
        guard let targetIndex = order.firstIndex(of: target) else { return }
        order.insert(column, at: targetIndex + (after ? 1 : 0))
        columnOrder = order
    }

    func reset() {
        visibleColumns = scope.defaultVisible
        columnOrder = MacSongsColumn.allCases
        columnWidths = Dictionary(uniqueKeysWithValues: MacSongsColumn.allCases.map { ($0, $0.defaultWidth) })
        showsHeader = true
        saveWidths()
    }

    private func key(_ name: String) -> String { "\(scope.keyPrefix).\(name).v1" }
}

struct MacSongTableHeader: View {
    let layout: MacSongTableLayout
    let ordinalWidth: CGFloat
    var isSelectionActive = false
    let sortOrder: LibrarySongSortOrder?
    var sortableCriteria: Set<LibrarySongSortCriterion>?
    let onSort: (LibrarySongSortCriterion) -> Void

    @State private var resizingColumn: MacSongsColumn?
    @State private var resizingStartWidth: CGFloat = 0
    @State private var dropTarget: MacSongsColumn?

    var body: some View {
        HStack(spacing: MacSongTableLayout.spacing) {
            Text(isSelectionActive ? "" : "#").frame(width: ordinalWidth, alignment: .leading)
            Color.clear.frame(width: MacSongTableLayout.artworkWidth, height: 1)
            ForEach(layout.activeColumns) { column in
                columnHeader(column)
            }
        }
        .frame(width: layout.contentWidth(ordinalWidth: ordinalWidth), alignment: .leading)
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(PMColor.textFaint)
    }

    private func columnHeader(_ column: MacSongsColumn) -> some View {
        Group {
            if let criterion = column.sortCriterion, sortableCriteria?.contains(criterion) ?? true {
                Button { onSort(criterion) } label: { columnLabel(column) }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(verbatim: sortDirection(for: criterion)))
            } else {
                columnLabel(column)
            }
        }
        .frame(width: layout.width(column), alignment: column.alignment)
        .contentShape(Rectangle())
        .background(dropTarget == column ? PMColor.brand.opacity(0.08) : .clear)
        .draggable(column.rawValue) { Text(verbatim: column.title).padding(8) }
        .dropDestination(for: String.self) { values, location in
            guard let value = values.first, let dragged = MacSongsColumn(rawValue: value) else { return false }
            layout.move(dragged, relativeTo: column, after: location.x >= layout.width(column) / 2)
            return true
        } isTargeted: { dropTarget = $0 ? column : nil }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(resizingColumn == column ? PMColor.brand : PMColor.dividerStrong.opacity(0.7))
                .frame(width: 1, height: 18)
                .frame(width: 10, height: 28, alignment: .trailing)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if resizingColumn != column {
                            resizingColumn = column
                            resizingStartWidth = layout.width(column)
                        }
                        layout.resize(column, to: resizingStartWidth + value.translation.width)
                    }
                    .onEnded { _ in
                        resizingColumn = nil
                        layout.saveWidths()
                    })
                .accessibilityLabel(Text(verbatim: column.title))
        }
        .accessibilityIdentifier("songTable.header.\(column.rawValue)")
    }

    private func columnLabel(_ column: MacSongsColumn) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: column.title).lineLimit(1).truncationMode(.tail)
            if let order = sortOrder, column.sortCriterion == order.criterion {
                Image(systemName: order.isAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
        }
        .frame(width: layout.width(column), alignment: column.alignment)
    }

    private func sortDirection(for criterion: LibrarySongSortCriterion) -> String {
        guard let order = sortOrder, order.criterion == criterion else { return "" }
        return String(localized: order.isAscending ? "smart_sort_ascending" : "smart_sort_descending")
    }
}

struct MacSongTableColumnOptions: View {
    @Bindable var layout: MacSongTableLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("songs_show_column_headers", isOn: $layout.showsHeader)
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("songs_display_columns")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                        GridItem(.flexible(), alignment: .topLeading),
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(MacSongsColumn.allCases) { column in
                        Toggle(isOn: Binding(
                            get: { layout.visibleColumns.contains(column) },
                            set: { _ in layout.toggle(column) }
                        )) {
                            Text(verbatim: column.title)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                        .disabled(column == .title)
                    }
                }
            }
            Divider()
            Button("reset") { layout.reset() }
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.brand)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(PMColor.text)
    }
}

struct MacSongTableDownloadIndicator: View {
    let song: Song
    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        let entry = sourceManager.offlineAudioSnapshotEntry(for: song)
        Group {
            if entry.snapshot.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("filter_downloaded"))
            } else {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
        .task(id: song) { await sourceManager.ensureOfflineAudioSnapshot(for: song) }
    }
}
#endif
