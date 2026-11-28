import SwiftUI
import PrimuseKit
import os
#if os(iOS)
import UIKit
#if DEBUG
@MainActor
enum SongListRenderDiagnostics {
    static var didBuildFolder: ((LibraryFolderNodeID) -> Void)?
}
#endif
#endif
#if os(macOS)
import AppKit

enum MacOrdinalColumn {
    /// 序号按等宽字体逐字算宽, 不经过排版(见 `SongListOrdinalColumn`)。
    static func width(for largestNumber: Int, minimum: CGFloat, fontSize: CGFloat, locale: Locale, showsNumbers: Bool = true) -> CGFloat {
        guard showsNumbers else { return 16 }
        let label = max(1, largestNumber).formatted(.number.locale(locale))
        return CGFloat(SongListOrdinalColumn.width(
            label: label,
            minimum: Double(minimum),
            fontSize: Double(fontSize)
        ))
    }
}
#endif

struct SongLibraryLocationRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let songID: String

    init(songID: String, id: UUID = UUID()) {
        self.id = id
        self.songID = songID
    }
}

struct FolderSongLocationRequest: Identifiable, Hashable {
    let nodeID: LibraryFolderNodeID
    let song: SongLibraryLocationRequest
    var id: UUID { song.id }
}

private struct FolderSongLocationRevision: Hashable {
    let nodeID: LibraryFolderNodeID?
    let indexRevision: Int
    let songOrderRevision: Int
}

@MainActor
@Observable
final class SongListLocation {
    private(set) var request: SongLibraryLocationRequest?
    private(set) var needsScroll = false
    private(set) var highlightedSongID: String?
    private(set) var viewportBounds: CGRect?
    private(set) var hasViewport = false
    /// 没有定位请求时视口变化（拖窗口大小）不逐帧通知各行；停下来后加一，行按新视口重判一次可见。
    private(set) var settledViewportRevision = 0
    @ObservationIgnored private var latestViewportBounds: CGRect?
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var viewportSettleTask: Task<Void, Never>?
    private let highlightDuration: Duration

    var currentViewportBounds: CGRect? { latestViewportBounds ?? viewportBounds }

    init(highlightDuration: Duration = .seconds(2.4)) {
        self.highlightDuration = highlightDuration
    }

    func locate(_ songID: String) {
        highlightTask?.cancel()
        highlightedSongID = nil
        if let latestViewportBounds, viewportBounds != latestViewportBounds {
            viewportBounds = latestViewportBounds
        }
        request = SongLibraryLocationRequest(songID: songID)
        needsScroll = !visibleIDs.contains(songID)
        if !needsScroll { reveal(songID, requestID: request?.id) }
    }

    func visibilityChanged(_ songID: String, visible: Bool) {
        if visible {
            visibleIDs.insert(songID)
            reveal(songID, requestID: request?.id)
        } else {
            visibleIDs.remove(songID)
        }
    }

    func setViewport(_ bounds: CGRect) {
        if latestViewportBounds == nil {
            visibleIDs.removeAll()
            hasViewport = true
            viewportBounds = bounds
        } else if request != nil, viewportBounds != bounds {
            viewportBounds = bounds
        } else if request == nil, latestViewportBounds != bounds {
            scheduleViewportSettled()
        }
        latestViewportBounds = bounds
    }

    /// 视口变了而行自己的位置没变（从下边缘拖矮窗口）时，行不会自己重判可见，`visibleIDs` 里留着
    /// 按旧视口记下的「可见」，下一次定位就只高亮不滚动。等尺寸停下来补一次通知，不必每一帧都重算所有行。
    private func scheduleViewportSettled() {
        viewportSettleTask?.cancel()
        viewportSettleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.settledViewportRevision &+= 1
        }
    }

    func reveal(_ songID: String, requestID: UUID?) {
        guard let request, request.id == requestID, request.songID == songID,
              highlightedSongID != songID else { return }
        needsScroll = false
        highlightedSongID = songID
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self, highlightDuration] in
            do { try await Task.sleep(for: highlightDuration) } catch { return }
            guard let self, self.request?.id == request.id else { return }
            self.highlightedSongID = nil
            self.request = nil
        }
    }

    func cancel() {
        highlightTask?.cancel()
        highlightTask = nil
        request = nil
        highlightedSongID = nil
        needsScroll = false
    }
}

extension EnvironmentValues {
    @Entry var songListLocation: SongListLocation? = nil
    @Entry var songLocationEmphasis: Double = 0
}

private struct SongLocationRowModifier: ViewModifier {
    let songID: String
    var appearance: SongListAppearance = .list
    @Environment(\.songListLocation) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var emphasis = 0.0

    func body(content: Content) -> some View {
        let usesViewport = location?.hasViewport == true
        let activeViewport = location?.request != nil ? location?.viewportBounds : nil
        // 只为登记观察：视口停下来后这个数加一，下面的可见性探针按新视口重算一次。不量视口的列表（iOS）不读。
        let _ = usesViewport ? location?.settledViewportRevision : nil
        let highlightID = location?.highlightedSongID == songID ? location?.request?.id : nil
        content
        .environment(\.songLocationEmphasis, emphasis)
        .background {
            if appearance == .list {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                    }
                    .opacity(emphasis)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background {
            // 时间线与封面外观的转角、淡入淡出只改绘制，探针量的是不变的槽位框。
            Color.clear
                .onScrollVisibilityChange(threshold: 0.9) { visible in
                    if !usesViewport { location?.visibilityChanged(songID, visible: visible) }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: Bool.self) { proxy in
            guard let viewport = activeViewport ?? location?.currentViewportBounds else { return false }
            let frame = proxy.frame(in: .global)
            let visible = frame.intersection(viewport)
            return frame.height > 0 && visible.width > 0 && visible.height >= frame.height * 0.9
        } action: { visible in
            if usesViewport { location?.visibilityChanged(songID, visible: visible) }
        }
        .task(id: highlightID) {
            guard highlightID != nil else {
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.35)) { emphasis = 0 }
                return
            }
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) { emphasis = 0 }
            do {
                try await Task.sleep(for: .milliseconds(35))
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.18)) { emphasis = 1 }
                try await Task.sleep(for: .milliseconds(1600))
                withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.65)) { emphasis = 0 }
            } catch { }
        }
        .onDisappear { location?.visibilityChanged(songID, visible: false) }
    }
}

// 封面墙也以歌曲 ID 标识封面；滚动目标用独立类型，避免定位到顶部头图。
private struct SongLocationScrollID: Hashable {
    let songID: String
}

private struct SongLocationReader: ViewModifier {
    let location: SongListLocation
    let revision: AnyHashable
    var prepare: (String) -> Void

    private struct Trigger: Equatable {
        let request: SongLibraryLocationRequest?
        let revision: AnyHashable
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.songListLocation, location)
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { location.cancel() }
                }
                .task(id: Trigger(request: location.request, revision: revision)) {
                    guard let request = location.request, location.needsScroll else { return }
                    prepare(request.songID)
                    await Task.yield()
                    guard !Task.isCancelled, location.request?.id == request.id,
                          location.needsScroll else { return }
                    proxy.scrollTo(SongLocationScrollID(songID: request.songID), anchor: .center)
                }
        }
    }
}

extension View {
    @ViewBuilder
    func songLocationRow(_ songID: String, assignsScrollID: Bool = true,
                         appearance: SongListAppearance = .list) -> some View {
        if assignsScrollID {
            modifier(SongLocationRowModifier(songID: songID, appearance: appearance))
                .id(SongLocationScrollID(songID: songID))
        } else {
            modifier(SongLocationRowModifier(songID: songID, appearance: appearance))
        }
    }

    func songLocationReader(
        _ location: SongListLocation,
        revision: some Hashable,
        prepare: @escaping (String) -> Void = { _ in }
    ) -> some View {
        modifier(SongLocationReader(location: location, revision: AnyHashable(revision), prepare: prepare))
    }
}

#if os(macOS)
private struct SongLocationPositionReader: ViewModifier {
    let location: SongListLocation
    let revision: AnyHashable
    let offset: (String, CGFloat) -> CGFloat?
    @State private var position = ScrollPosition()
    @State private var viewportHeight: CGFloat = 0

    private struct Trigger: Equatable {
        let request: SongLibraryLocationRequest?
        let revision: AnyHashable
        let viewportHeight: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .environment(\.songListLocation, location)
            .scrollPosition($position)
            .songLocationViewport(location)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { location.cancel() }
            }
            .task(id: Trigger(request: location.request, revision: revision, viewportHeight: viewportHeight)) {
                guard let request = location.request, location.needsScroll, viewportHeight > 0,
                      let target = offset(request.songID, viewportHeight) else { return }
                await Task.yield()
                guard !Task.isCancelled, location.request?.id == request.id, location.needsScroll else { return }
                position.scrollTo(y: max(0, target))
            }
    }
}

extension View {
    func songLocationViewport(_ location: SongListLocation?, topInset: CGFloat = 0) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            let bounds = proxy.frame(in: .global)
            return CGRect(x: bounds.minX, y: bounds.minY + topInset,
                          width: bounds.width, height: max(0, bounds.height - topInset))
        } action: { location?.setViewport($0) }
    }

    func songLocationScrollPosition(
        _ location: SongListLocation,
        revision: some Hashable,
        offset: @escaping (String, CGFloat) -> CGFloat?
    ) -> some View {
        modifier(SongLocationPositionReader(location: location, revision: AnyHashable(revision), offset: offset))
    }
}
#endif

struct LocateCurrentSongButton: View {
    var isEditing = false
    var titled = false
    let contains: (String) -> Bool
    var isVisible: (String) -> Bool = { _ in true }
    let locate: (String, Bool) -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var filteredTarget: String?

    func targetID(player: AudioPlayerService, library: MusicLibrary) -> String? {
        guard !isEditing, !player.isLiveRadio, !player.currentItemIsSpokenWord,
              let song = player.currentSong else { return nil }
        let canonicalID = NowPlayingLibraryActions.locationSongID(for: song, library: library)
        if contains(canonicalID) { return canonicalID }
        return canonicalID != song.id && contains(song.id) ? song.id : nil
    }

    var body: some View {
        Group {
            if let songID = targetID(player: player, library: library) {
                Button {
                    if isVisible(songID) { locate(songID, false) }
                    else { filteredTarget = songID }
                } label: {
                    #if os(macOS)
                    // Mac 上它摆在页头 / 工具条那一排里: 跟旁边的键同一种玻璃键, 不是系统的描边按钮。
                    Image(systemName: "scope")
                        .macControlChrome(iconOnly: true)
                    #else
                    PMToolbarItemLabel("locate_current_song", systemImage: "scope", titled: titled)
                    #endif
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel(Text("locate_current_song"))
                .accessibilityIdentifier("songList.locateCurrent")
                .help(Text("locate_current_song"))
            }
        }
        .filteredSongLocationAlert($filteredTarget, locate: locateClearingFilters)
    }

    /// 「清除筛选并定位」：确认时这首还在页面里才定位。
    func locateClearingFilters(_ songID: String) {
        if contains(songID) { locate(songID, true) }
    }

    #if os(iOS)
    /// 顶栏四颗键收进「⋯」系统菜单时，菜单顶上那一排里的定位（`target` 是页面用 `targetID` 算好的那首，
    /// 没有就不出现）。菜单项上挂不住 alert：要先清掉筛选时只把歌记进 `filteredTarget`，
    /// 由页面在菜单外面挂 `filteredSongLocationAlert` 来问。
    @ViewBuilder
    func menuItem(target songID: String?, filteredTarget pageTarget: Binding<String?>) -> some View {
        if let songID {
            PMMenuQuickActionButton(
                shortKey: "toolbar_quick_locate_short",
                fullKey: "locate_current_song",
                systemImage: "scope"
            ) {
                if isVisible(songID) { locate(songID, false) }
                else { pageTarget.wrappedValue = songID }
            }
            .accessibilityIdentifier("songList.locateCurrent")
        }
    }
    #endif
}

extension View {
    /// 要定位的歌被筛选挡住时问一句「清除筛选并定位」。在菜单里点的定位把歌记进 `target`，
    /// 这个 alert 挂在菜单外面的页面上（菜单项上挂不住）。
    func filteredSongLocationAlert(_ target: Binding<String?>, locate: @escaping (String) -> Void) -> some View {
        alert("locate_current_song", isPresented: Binding(
            get: { target.wrappedValue != nil },
            set: { if !$0 { target.wrappedValue = nil } }
        ), presenting: target.wrappedValue) { songID in
            Button("clear_filters_and_locate") { locate(songID) }
            Button("cancel", role: .cancel) {}
        }
    }
}

private struct SongLocationScrollTrigger: Equatable {
    let requestID: UUID?
    let songID: String?
    let rowOrderRevision: Int
}

#if os(macOS)
private enum MacSongLocationScrollTarget: Equatable {
    case windowedRow(offset: Int, rowHeight: CGFloat)
    case element(Int)
}

private struct MacSongLocationScrollRequest: Equatable {
    let requestID: UUID?
    let songID: String?
    let rowOrderRevision: Int
    let target: MacSongLocationScrollTarget?
    let rowCount: Int
    let resetKey: String
}

private struct MacSongLocationTaskIdentity: Equatable {
    let request: MacSongLocationScrollRequest
    let chromeHeight: Int
    let viewportHeight: Int
    let viewportWidth: Int
}

private struct MacSongScrollWindowMetrics: Equatable {
    let firstVisibleRow: Int
    let viewportHeight: Int
    let viewportWidth: Int
    /// 离开了最顶上。刚进页面只建了一屏的行, 一滚就要把缓冲行补上。
    var isScrolled = false
}

/// Scrolling invalidates only the bounded row window. The page header and
/// library observers keep their existing view values while the window moves.
struct MacWindowedSongScrollView<Header: View, RowContent: View>: View {
    let axes: Axis.Set
    let rowCount: Int
    let rowHeight: CGFloat
    @Binding var chromeHeight: CGFloat
    @Binding var viewportHeight: CGFloat
    @ViewBuilder let header: Header
    @ViewBuilder let rowContent: (Int) -> RowContent

    @State private var firstVisibleRow = 0
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        let range = SongListScrollWindow.range(
            totalCount: rowCount,
            firstVisibleRow: firstVisibleRow,
            viewportHeight: Double(viewportHeight),
            rowHeight: Double(rowHeight)
        )
        let rowWidth = max(0, viewportWidth - PMSpace.xxxl * 2)
        ScrollView(axes, showsIndicators: axes.contains(.horizontal)) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(minWidth: viewportWidth, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        guard abs(chromeHeight - height) > 0.5 else { return }
                        chromeHeight = height
                    }

                Color.clear
                    .frame(height: CGFloat(range.lowerBound) * rowHeight)
                    .frame(minWidth: viewportWidth, alignment: .leading)
                    .accessibilityHidden(true)

                ForEach(range, id: \.self) { position in
                    rowContent(position)
                        .frame(minWidth: rowWidth, alignment: .leading)
                        .frame(height: rowHeight)
                        .padding(.horizontal, PMSpace.xxxl)
                }

                Color.clear
                    .frame(height: CGFloat(rowCount - range.upperBound) * rowHeight + 112)
                    .frame(minWidth: viewportWidth, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: viewportWidth, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .scrollIndicators(.hidden, axes: .vertical)
        .scrollIndicators(axes.contains(.horizontal) ? .visible : .hidden, axes: .horizontal)
        .onScrollGeometryChange(for: MacSongScrollWindowMetrics.self) { geometry in
            let offset = max(0, geometry.visibleRect.minY - chromeHeight)
            let row = Int(offset / max(1, rowHeight))
            let stride = SongListScrollWindow.rowStride
            return MacSongScrollWindowMetrics(
                firstVisibleRow: row / stride * stride,
                viewportHeight: Int(geometry.containerSize.height.rounded()),
                viewportWidth: Int(geometry.containerSize.width.rounded())
            )
        } action: { _, metrics in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                firstVisibleRow = metrics.firstVisibleRow
                if viewportHeight != CGFloat(metrics.viewportHeight) {
                    viewportHeight = CGFloat(metrics.viewportHeight)
                }
                if viewportWidth != CGFloat(metrics.viewportWidth) {
                    viewportWidth = CGFloat(metrics.viewportWidth)
                }
            }
        }
    }
}

/// Keeps the macOS table header and native scroll view alive while only the
/// result layout changes between table, compact, and grid presentation. The
/// page chrome above the table is laid out outside this surface and never scrolls.
private struct MacSongScrollSurface<Chrome: View, Results: View>: View {
    let allowsHorizontalScrolling: Bool
    let rowCount: Int
    let rowHeight: CGFloat?
    let request: MacSongLocationScrollRequest
    @ViewBuilder let chrome: Chrome
    @ViewBuilder let results: (Range<Int>, CGFloat) -> Results

    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var firstVisibleRow = 0
    @State private var chromeHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var previousResetKey: String?
    /// 刚进页面时只建看得见的那几行, 上下的缓冲行等入场动画走完或一开始滚动再补:
    /// 一次建五十来行在 Debug 构建里要两百毫秒, 正压在换页那一帧上, 进页面就慢半拍。
    @State private var buildsFullWindow = false
    @Environment(\.songListLocation) private var songLocation

    var body: some View {
        GeometryReader { geometry in
            scrollContent
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            buildsFullWindow = true
        }
    }

    /// 停在最上面时第一帧要建的行: 一屏能看见的, 再多两行。
    private func entranceRange(
        _ full: Range<Int>,
        visibleRow: Int,
        rowHeight: CGFloat
    ) -> Range<Int> {
        guard !buildsFullWindow, visibleRow == 0, request.target == nil, full.lowerBound == 0 else {
            return full
        }
        let height = viewportHeight > 0 ? viewportHeight : 720
        let visibleCount = Int((height / max(1, rowHeight)).rounded(.up)) + 2
        return full.lowerBound..<min(full.upperBound, full.lowerBound + visibleCount)
    }

    @ViewBuilder
    private var scrollContent: some View {
        let resetsToTop = previousResetKey.map { key in
            key != request.resetKey && request.target == nil
        } ?? false
        let visibleRow = resetsToTop ? 0 : firstVisibleRow
        let range = rowHeight.map {
            entranceRange(
                SongListScrollWindow.range(
                    totalCount: rowCount,
                    firstVisibleRow: visibleRow,
                    viewportHeight: Double(viewportHeight),
                    rowHeight: Double($0)
                ),
                visibleRow: visibleRow,
                rowHeight: $0
            )
        } ?? 0..<rowCount

        ScrollView(
            allowsHorizontalScrolling ? [.vertical, .horizontal] : .vertical
        ) {
            // 表头作为置顶的分区头: 纵向滚动时钉在可见区顶部, 横向仍与行一起滚动,
            // 列标题始终可见。
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    results(range, viewportWidth)
                        .frame(
                            minWidth: viewportWidth,
                            alignment: .leading
                        )

                    Color.clear
                        .frame(height: 112)
                        .frame(minWidth: viewportWidth, alignment: .leading)
                        .accessibilityHidden(true)
                } header: {
                    chrome
                        .frame(minWidth: viewportWidth, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            guard abs(chromeHeight - height) > 0.5 else { return }
                            chromeHeight = height
                        }
                }
            }
            .frame(minWidth: viewportWidth, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .songLocationViewport(songLocation, topInset: chromeHeight)
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicators(
            allowsHorizontalScrolling ? .visible : .hidden,
            axes: .horizontal
        )
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: MacSongScrollWindowMetrics.self) { geometry in
            let effectiveRowHeight = max(1, rowHeight ?? 1)
            let offset = max(0, geometry.visibleRect.minY - chromeHeight)
            let row = rowHeight == nil ? 0 : Int(offset / effectiveRowHeight)
            let stride = SongListScrollWindow.rowStride
            return MacSongScrollWindowMetrics(
                firstVisibleRow: row / stride * stride,
                viewportHeight: Int(geometry.containerSize.height.rounded()),
                viewportWidth: Int(geometry.containerSize.width.rounded()),
                isScrolled: geometry.visibleRect.minY > 1
            )
        } action: { _, metrics in
            withTransaction(Self.noAnimationTransaction) {
                if !buildsFullWindow, metrics.isScrolled {
                    buildsFullWindow = true
                }
                firstVisibleRow = metrics.firstVisibleRow
                if viewportHeight != CGFloat(metrics.viewportHeight) {
                    viewportHeight = CGFloat(metrics.viewportHeight)
                }
                if viewportWidth != CGFloat(metrics.viewportWidth) {
                    viewportWidth = CGFloat(metrics.viewportWidth)
                }
            }
        }
        .onChange(of: request.resetKey, initial: true) { _, newKey in
            let shouldReset = previousResetKey.map { $0 != newKey } ?? false
            previousResetKey = newKey
            guard shouldReset else { return }
            withTransaction(Self.noAnimationTransaction) {
                if request.target == nil {
                    firstVisibleRow = 0
                    scrollPosition.scrollTo(x: 0, y: 0)
                } else {
                    scrollPosition.scrollTo(x: 0)
                }
            }
        }
        .task(id: locationTaskIdentity) {
            guard let target = request.target else { return }
            positionWindow(for: target)
            for delay in [0, 16, 34, 68, 120] {
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(delay))
                    } catch {
                        return
                    }
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled, self.request == request else { return }
                scroll(to: target, rowCount: request.rowCount)
            }
        }
    }

    private var locationTaskIdentity: MacSongLocationTaskIdentity {
        MacSongLocationTaskIdentity(
            request: request,
            chromeHeight: Int(chromeHeight.rounded()),
            viewportHeight: Int(viewportHeight.rounded()),
            viewportWidth: Int(viewportWidth.rounded())
        )
    }

    private func positionWindow(for target: MacSongLocationScrollTarget) {
        guard case .windowedRow(let offset, _) = target else { return }
        withTransaction(Self.noAnimationTransaction) {
            firstVisibleRow = offset
        }
    }

    private func scroll(to target: MacSongLocationScrollTarget, rowCount: Int) {
        switch target {
        case .windowedRow(let offset, let targetRowHeight):
            guard (0..<rowCount).contains(offset) else { return }
            let centeredOffset = chromeHeight
                + CGFloat(offset) * targetRowHeight
                - max(0, (viewportHeight - targetRowHeight) / 2)
            scrollPosition.scrollTo(y: max(0, centeredOffset))
        case .element(let position):
            guard (0..<rowCount).contains(position) else { return }
            scrollPosition.scrollTo(id: position, anchor: .center)
        }
    }

    private static var noAnimationTransaction: Transaction {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }
}
#endif

/// Reference-backed storage prevents AttributeGraph from applying
/// `Array<Song>.==` to the list cache whenever metadata changes. Song's
/// synthesized equality includes lyricsText, so a value-backed SwiftUI state
/// made each background backfill publication walk the full lyrics library.
@MainActor
@Observable
final class SongListRowModel {
    private final class SongReference {
        let value: Song

        init(_ value: Song) {
            self.value = value
        }
    }

    private var reference: SongReference

    var song: Song { reference.value }

    init(song: Song) {
        reference = SongReference(song)
    }

    func replace(with song: Song) {
        // SongReference deliberately has identity equality. Assigning a new
        // Song value therefore notifies only this row without Observation
        // comparing the complete lyricsText payload first.
        reference = SongReference(song)
    }
}

@MainActor
@Observable
final class SongListPositionModel {
    private(set) var row: SongListRowIdentity?

    init(row: SongListRowIdentity?) {
        self.row = row
    }

    func replace(with row: SongListRowIdentity?) {
        guard self.row != row else { return }
        self.row = row
    }
}

/// Rows own their models. Keep a weak lookup so metadata edits and sorts can update every
/// mounted or prefetched row without retaining the songs from a long scrolling session.
private struct SongListLiveModels<Key: Hashable, Model: AnyObject> {
    private struct Entry { weak var model: Model? }
    private var entries: [Key: Entry] = [:]
    private var nextSweep = 256

    subscript(key: Key) -> Model? { entries[key]?.model }

    mutating func store(_ model: Model, for key: Key) {
        if entries.count >= nextSweep { compact() }
        entries[key] = Entry(model: model)
    }

    mutating func compact(keeping keep: (Key) -> Bool = { _ in true }) {
        entries = entries.filter { $0.value.model != nil && keep($0.key) }
        nextSweep = entries.count + max(256, entries.count)
    }

    func forEach(_ visit: (Key, Model) -> Void) {
        for (key, entry) in entries {
            if let model = entry.model { visit(key, model) }
        }
    }
}

@MainActor
@Observable
final class SongListCache {

    /// The worker builds this immutable reference off the main actor. Publishing
    /// it is O(1), instead of rebuilding dictionaries and aggregates while the
    /// navigation animation or a scroll gesture is running.
    @ObservationIgnored private var snapshot: SongListSnapshot?

    @ObservationIgnored private var rowModelsByID = SongListLiveModels<String, SongListRowModel>()
    @ObservationIgnored private var positionModelsByPosition = SongListLiveModels<Int, SongListPositionModel>()
    @ObservationIgnored private var projectionEntry: ProjectionEntry?

    private(set) var hasSnapshot = false
    private(set) var positionCount = 0
    private(set) var rowOrderRevision = 0
    private(set) var songCount = 0
    private(set) var playableCount = 0
    private(set) var totalDuration: TimeInterval = 0
    private(set) var coverSongID: String?

}

extension SongListCache {
    private struct ProjectionKey: Equatable {
        let snapshotIdentity: ObjectIdentifier
        let sourceID: String?
        let query: String
        let restrictsToDownloaded: Bool
        let filterRevision: Int
        let replacementToken: UUID
    }

    private struct ProjectionEntry {
        let key: ProjectionKey
        let value: SongListProjection
    }

    var rows: [SongListRowIdentity] { snapshot?.rows ?? [] }
    var orderedSongIDs: [String] { snapshot?.orderedSongIDs ?? [] }
    var sectionIndexEntries: [SongListSectionIndexEntry] {
        snapshot?.sectionIndexEntries ?? []
    }
    var isEmpty: Bool { !hasSnapshot }

    func songCount(forSourceID sourceID: String) -> Int {
        snapshot?.sourceCounts[sourceID, default: 0] ?? 0
    }

    func publish(
        _ snapshot: SongListSnapshot,
        pruneRowModels: Bool,
        resolve: (String) -> Song?
    ) {
        rowModelsByID.compact { !pruneRowModels || snapshot.songIDs.contains($0) }
        // Full source publications may change metadata without per-row replacement IDs.
        rowModelsByID.forEach { songID, model in
            if let song = resolve(songID) {
                model.replace(with: song)
            }
        }
        self.snapshot = snapshot
        coverSongID = snapshot.coverSongID
        projectionEntry = nil
        if !hasSnapshot {
            hasSnapshot = true
        }
        if positionCount != snapshot.rows.count {
            positionCount = snapshot.rows.count
            songCount = snapshot.rows.count
        }
        if playableCount != snapshot.playableCount {
            playableCount = snapshot.playableCount
        }
        if totalDuration != snapshot.totalDuration {
            totalDuration = snapshot.totalDuration
        }
        positionModelsByPosition.compact()
        positionModelsByPosition.forEach { position, model in
            model.replace(with: row(at: position))
        }
        rowOrderRevision &+= 1
    }

    func patch(_ replacements: [String: Song], resolve: (String) -> Song?) {
        guard !replacements.isEmpty else { return }
        for (songID, song) in replacements {
            rowModelsByID[songID]?.replace(with: song)
        }
        if let coverSongID, let replacement = replacements[coverSongID],
           replacement.coverArtFileName?.isEmpty != false {
            self.coverSongID = snapshot?.orderedSongIDs.first {
                resolve($0)?.coverArtFileName?.isEmpty == false
            }
        } else if coverSongID == nil {
            coverSongID = replacements.values.first { $0.coverArtFileName?.isEmpty == false }?.id
        }
    }

    func contains(songID: String) -> Bool {
        snapshot?.songIDs.contains(songID) == true
    }

    func row(at position: Int) -> SongListRowIdentity? {
        guard let snapshot, snapshot.rows.indices.contains(position) else { return nil }
        return snapshot.rows[position]
    }

    func position(of songID: String) -> Int? {
        snapshot?.orderedSongIDs.firstIndex(of: songID)
    }

    func positionModel(at position: Int) -> SongListPositionModel {
        if let model = positionModelsByPosition[position] {
            return model
        }
        let model = SongListPositionModel(row: row(at: position))
        positionModelsByPosition.store(model, for: position)
        return model
    }

    func rowModel(id: String, song: @autoclosure () -> Song?) -> SongListRowModel? {
        if let model = rowModelsByID[id] {
            return model
        }
        guard let song = song() else { return nil }
        let model = SongListRowModel(song: song)
        rowModelsByID.store(model, for: id)
        return model
    }

    fileprivate func projection(
        sourceID: String?,
        query: String,
        includedSongIDs: Set<String>?,
        filterRevision: Int,
        replacementToken: UUID,
        resolve: (String) -> Song?
    ) -> SongListProjection {
        _ = rowOrderRevision
        guard let snapshot else { return .empty }
        let candidates: (
            rows: [SongListRowIdentity],
            playableCount: Int
        )
        if let sourceID {
            guard let partition = snapshot.sourcePartition(forSourceID: sourceID) else {
                return .empty
            }
            candidates = (partition.rows, partition.playableCount)
        } else {
            candidates = (snapshot.rows, snapshot.playableCount)
        }
        guard !query.isEmpty || includedSongIDs != nil else {
            return SongListProjection(
                rows: candidates.rows,
                playableCount: candidates.playableCount
            )
        }

        let key = ProjectionKey(
            snapshotIdentity: ObjectIdentifier(snapshot),
            sourceID: sourceID,
            query: query,
            restrictsToDownloaded: includedSongIDs != nil,
            filterRevision: filterRevision,
            replacementToken: replacementToken
        )
        if projectionEntry?.key == key, let cached = projectionEntry?.value {
            return cached
        }

        let interval = SongListPerformanceSignpost.signposter.beginInterval(
            "FilteredProjection",
            "count: \(candidates.rows.count, privacy: .public), hasSource: \(sourceID != nil, privacy: .public), downloaded: \(includedSongIDs != nil, privacy: .public), queryLength: \(query.count, privacy: .public)"
        )
        var rows: [SongListRowIdentity] = []
        var playableCount = 0
        rows.reserveCapacity(candidates.rows.count)
        // 搜索词按空白分词, 每个词落在歌名、艺人、专辑任一处即可(「周杰伦 晴天」)。
        let findQuery = LibraryFindPolicy.query(query)
        for row in candidates.rows {
            if let includedSongIDs, !includedSongIDs.contains(row.id) { continue }
            guard let song = resolve(row.id) else { continue }
            if let findQuery, !LibraryFindPolicy.matches(findQuery, song: song) {
                continue
            }
            let id = row.id
            rows.append(SongListRowIdentity(id: id, offset: rows.count))
            if song.isPlayable {
                playableCount += 1
            }
        }
        let value = SongListProjection(
            rows: rows,
            playableCount: playableCount
        )
        projectionEntry = ProjectionEntry(key: key, value: value)
        SongListPerformanceSignpost.signposter.endInterval(
            "FilteredProjection",
            interval,
            "resultCount: \(rows.count, privacy: .public)"
        )
        return value
    }
}

/// 文件夹页的歌曲顺序: 默认曲目顺序, 在排序菜单里选了别的维度才跟随歌曲列表。
enum LibraryFolderSongOrderPreference {
    static let followsListSortKey = "library.folderFollowsListSort.v1"
}

@MainActor
@Observable
private final class LibraryFolderBrowserCache {
    enum QueryScope: Hashable {
        case visible
        case action
    }

    private struct OrderedQueryKey: Hashable {
        let folderRevision: Int
        let rowOrderRevision: Int
        let nodeID: LibraryFolderNodeID
        let scope: QueryScope
        let followsListSort: Bool
    }

    @ObservationIgnored private var indexReference: LibraryFolderIndex?
    @ObservationIgnored private var orderedQueries: [OrderedQueryKey: [String]] = [:]
    private(set) var hasIndex = false
    private(set) var revision = 0
    /// false = 曲目顺序(默认): 一个文件夹通常就是一张专辑, 按碟号/曲号读;
    /// true = 跟随歌曲列表当前的排序。
    var followsListSort = false

    var index: LibraryFolderIndex? {
        _ = revision
        return indexReference
    }

    func publish(_ index: LibraryFolderIndex) {
        indexReference = index
        orderedQueries.removeAll(keepingCapacity: true)
        if !hasIndex { hasIndex = true }
        revision &+= 1
    }

    func node(withID id: LibraryFolderNodeID) -> LibraryFolderNode? {
        index?.node(withID: id)
    }

    func children(of id: LibraryFolderNodeID) -> [LibraryFolderNode] {
        index?.children(of: id) ?? []
    }

    func rootNodes(sourceID: String?) -> [LibraryFolderNode] {
        guard let index else { return [] }
        return LibraryFolderBrowsePolicy.rootNodes(in: index, sourceID: sourceID)
    }

    func orderedSongIDs(
        in nodeID: LibraryFolderNodeID,
        scope: QueryScope,
        listCache: SongListCache
    ) -> [String] {
        let rowOrderRevision = listCache.rowOrderRevision
        let key = OrderedQueryKey(
            folderRevision: revision,
            rowOrderRevision: rowOrderRevision,
            nodeID: nodeID,
            scope: scope,
            followsListSort: followsListSort
        )
        if let cached = orderedQueries[key] { return cached }
        guard let index else { return [] }

        if !followsListSort {
            let ordered = LibraryFolderBrowsePolicy.trackOrderedSongIDs(
                in: nodeID,
                scope: scope == .visible ? .direct : .descendants,
                index: index,
                isVisible: listCache.isEmpty ? { _ in true } : { listCache.contains(songID: $0) }
            )
            orderedQueries[key] = ordered
            return ordered
        }

        let ordered: [String]
        switch scope {
        case .visible:
            ordered = LibraryFolderBrowsePolicy.visibleSongIDs(
                in: nodeID,
                index: index,
                orderedBy: listCache.orderedSongIDs
            )
        case .action:
            ordered = LibraryFolderBrowsePolicy.actionSongIDs(
                in: nodeID,
                index: index,
                orderedBy: listCache.orderedSongIDs
            )
        }
        orderedQueries[key] = ordered
        return ordered
    }
}

private struct SongListProjection {
    let rows: [SongListRowIdentity]
    let playableCount: Int

    var orderedSongIDs: [String] { rows.map(\.id) }

    static let empty = SongListProjection(rows: [], playableCount: 0)
}

/// Keeps progress-only mutations below the song-list observation boundary.
/// Revealing or hiding the toolbar status must not invalidate the 20,000-row
/// parent view while the prepared snapshot is being published.
@MainActor
@Observable
private final class SongListSortProgressModel {
    private var state = SongListSortProgressState()

    var generation: Int? { state.generation }
    var order: LibrarySongSortOrder? { state.order }
    var isVisible: Bool { state.isVisible }

    @discardableResult
    func begin(generation: Int, order: LibrarySongSortOrder) -> Bool {
        state.begin(generation: generation, order: order)
    }

    @discardableResult
    func reveal(generation: Int) -> Bool {
        state.reveal(generation: generation)
    }

    @discardableResult
    func markWaitingForPublication(generation: Int) -> Bool {
        state.markWaitingForPublication(generation: generation)
    }

    @discardableResult
    func markPublished(generation: Int) -> Bool {
        state.markPublished(generation: generation)
    }

    @discardableResult
    func finish(generation: Int) -> Bool {
        state.finish(generation: generation)
    }

    @discardableResult
    func cancel(generation: Int) -> Bool {
        state.cancel(generation: generation)
    }
}

private struct SongListSortProgressIndicator: View {
    let progress: SongListSortProgressModel

    @ViewBuilder
    var body: some View {
        if progress.isVisible, let order = progress.order {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: progressMessage(for: order))
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: progressMessage(for: order)))
            .accessibilityIdentifier("songSortProgress")
        }
    }

    private func localizedSortLabel(_ order: LibrarySongSortOrder) -> String {
        SongListView.SongSortOrder(libraryOrder: order).label
    }

    private func progressMessage(for order: LibrarySongSortOrder) -> String {
        String(
            format: String(localized: "song_sort_progress_format"),
            localizedSortLabel(order)
        )
    }
}

struct SongListView: View {
    @AppStorage(LibraryRowNumberPreferences.storageKey)
    private var showsRowNumbers = LibraryRowNumberPreferences.defaultValue
    @Environment(AudioPlayerService.self) private var player
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:「⋯」并进系统溢出菜单,按钮分组并标优先级。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    /// 资料库分类挪进了 Duo 竖栏:右上角几颗键一律收进「⋯」,给竖栏中间腾地方。
    @Environment(\.librarySectionRailActive) private var sectionRailActive
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    /// Keep only a lightweight scope in the view identity. Storing `[Song]`
    /// here made SwiftUI/AttributeGraph compare every Song (including its full
    /// lyricsText) whenever an ancestor refreshed.
    private let scope: Scope
    private let onOpenSources: (() -> Void)?
    @Binding private var locationRequest: SongLibraryLocationRequest?
    @State private var songLocation = SongListLocation()
    private var locatedSongID: String? { songLocation.request?.songID }
    @State private var sortOrder: SongSortOrder
    @State private var songFilter: SongFilter
    @State private var downloadedSongIDs: Set<String> = []
    /// 目录里的离线状态(`songOffline`)已经补全到当前这一代:「已下载」筛选与排序可以由目录给。
    @State private var catalogOfflineIsCurrent = false
    @State private var downloadedFilterRevision = 0
    @State private var downloadedFilterGeneration = 0
    @State private var downloadedFilterTask: Task<Void, Never>?
    @State private var isDownloadedFilterLoading = false
    @State private var sortValuesVersion = SongListSortValuesVersion()
    @State private var listCache = SongListCache()
    /// 曲库目录可读时平铺列表的数据源(见 `usesCatalogList`)。
    @State private var catalogList = SongListCatalogList()
    #if os(macOS)
    /// 目录列表里要定位的那首在第几行(按行号查出来;对哪首、哪一版行号查的一并记着)。
    @State private var catalogLocatedRow: SongListCatalogLocatedRow?
    /// 目录列表时「加入歌单」先按 id 取好歌再弹框。
    @State private var catalogBatchSongs: [Song] = []
    #endif
    @State private var searchText: String = ""
    #if os(iOS)
    /// 页内搜索真正拿去过滤的词: 停手一小会儿才跟上输入, 整库几十万首时不必每敲一个字
    /// 就在主线程过一遍全表。
    @State private var appliedSearchText: String = ""
    /// 「⋯」菜单里点了定位、那首歌却被筛选挡住：菜单项上挂不住 alert，「清除筛选并定位」挂在页面上。
    @State private var filteredLocationTarget: String?
    #endif
    @State private var sortGeneration: Int = 0
    @State private var sortTask: Task<Void, Never>?
    @State private var sortFeedbackTask: Task<Void, Never>?
    @State private var sortFeedbackDeadline: ContinuousClock.Instant?
    @State private var sortProgress = SongListSortProgressModel()
    @State private var sortRequestActive = false
    @State private var activeSortIsExplicit = false
    @State private var isListInteracting = false
    @State private var pendingSnapshot: SongListSnapshot?
    @State private var pendingSnapshotPrunesRows = false
    @State private var pendingSnapshotIsExplicitSort = false
    @State private var pendingSnapshotGeneration = 0
    @State private var pendingSnapshotOrder: LibrarySongSortOrder?
    @State private var showNoScraperSourceAlert = false
    @State private var selection = SongSelectionModel()
    @State private var browseMode: LibrarySongBrowseMode
    #if os(iOS)
    /// 极简导航的「歌曲」页顶上放「开始听」那一行卡片(没有首页时的入口)。
    @Environment(\.songListShowsListeningIntents) private var showsListeningIntentsSetting
    @State private var presentedBrowseMode: LibrarySongBrowseMode
    @State private var browseModeTransitionTask: Task<Void, Never>?
    @State private var isBrowseModeTransitioning = false
    #endif
    #if os(macOS)
    @AppStorage(LibrarySongBrowseModePreference.storageKey)
    private var storedBrowseModeRawValue = LibrarySongBrowseMode.flat.rawValue
    #else
    @AppStorage(LibrarySongBrowseModePreference.storageKey)
    private var storedBrowseModeRawValue = LibrarySongBrowseMode.folder.rawValue
    #endif
    @State private var folderCache = LibraryFolderBrowserCache()
    @State private var pendingFolderLocation: SongLibraryLocationRequest?
    #if os(iOS)
    @State private var folderLocationDestination: FolderSongLocationRequest?
    #endif
    @AppStorage(LibraryFolderSongOrderPreference.followsListSortKey)
    private var folderFollowsListSort = false
    /// 目录被挡住时点「目录」的说明。iOS 上点的键可能在「⋯」系统菜单里，说明框挂在页面上。
    @State private var explainsFolderBlocker = false
    @State private var explainedFolderBlocker = LibraryFolderBrowseBlocker.downloadedFilter
    @State private var showsHomeFolders = false
    @State private var folderIndexStore = LibraryFolderIndexStore()
    @State private var folderIndexTask: Task<Void, Never>?
    @State private var folderIndexGeneration = 0
    @State private var folderSourceRevision = 0
    @State private var folderIndexScopeToken = UUID()
    #if os(macOS)
    @State private var macViewMode: MacSongsViewMode = .list
    @Environment(\.locale) private var locale
    @State private var macRowDensity: MacSongsRowDensity = .standard
    @State private var tableLayout = MacSongTableLayout(scope: .library)
    @State private var macFolderPath: [LibraryFolderNodeID] = []
    /// 当前选中的数据源过滤 (nil = 全部)。设计稿 SourceFilterChips 是可点切换的。
    @State private var selectedSourceID: String? = nil
    @State private var showViewOptions = false
    @State private var showAddVisibleToPlaylist = false
    // Bind context-menu sheets to the selected value itself.  A separate
    // `songID` + `isPresented` pair can publish in either order when a menu
    // closes, letting SwiftUI create a permanently empty sheet before the ID
    // becomes visible.
    @State private var contextAddToPlaylistSong: Song?
    @State private var contextSongInfoSong: Song?
    @State private var contextTagEditorSong: Song?
    @State private var contextShareSong: Song?
    @State private var contextPlaybackRangeRequest: SongPlaybackRangeEditor.Request?
    /// 右键菜单里的「编辑歌词」「重新读取文件标签」交给 `macSongActionHost`，和 iPhone 长按走同一套。
    @State private var contextSongAction: SongRowActionRequest?
    @State private var exportError: String?
    /// songID → 播放次数, 由 PlayHistory 一次性折叠而来。重建只发生在
    /// onAppear 和 PlayHistory 变更通知时, 而不是每行重算 (否则 LazyVStack
    /// 滚动时每实例化一行都要 O(5000) 折叠+建字典)。
    @State private var playCountsBySongID: [String: Int] = [:]
    @State private var playCountsTask: Task<Void, Never>?
    #endif

    enum Scope: Hashable, Sendable {
        case library
        case source(String)

        @MainActor
        func showsAudiobookshelfContents(in sources: SourcesStore) -> Bool {
            guard case .source(let id) = self else { return false }
            return sources.source(id: id)?.type == .audiobookshelf
        }

        @MainActor
        func songs(in library: MusicLibrary, sources: SourcesStore) -> [Song] {
            switch self {
            case .library:
                return library.musicSongs
            case .source(let id):
                let visible = library.visibleSongs(forSourceID: id)
                if showsAudiobookshelfContents(in: sources) { return visible }
                let excluded = library.nonMusicSongIDs
                return excluded.isEmpty ? visible : visible.filter { !excluded.contains($0.id) }
            }
        }

        var snapshotCacheKey: String {
            switch self {
            case .library:
                return SongListSnapshotStore.libraryScopeKey
            case .source(let sourceID):
                return SongListSnapshotStore.sourceScopeKey(sourceID)
            }
        }
    }

    private struct ProviderFolderHierarchyInput: Sendable {
        let syncIndex: SourceSyncIndex
        let rootDisplayNames: [String: String]
        let usesIndexedRoots: Bool
    }

    enum SongFilter: String, CaseIterable, Hashable, Sendable {
        case all
        case downloaded
        case offlineAvailable

        var label: LocalizedStringKey {
            switch self {
            case .all: return "search_chip_all"
            case .downloaded: return "filter_downloaded"
            case .offlineAvailable: return "filter_offline_available"
            }
        }

        var icon: String {
            switch self {
            case .all: return "music.note.list"
            case .downloaded: return "arrow.down.circle.fill"
            case .offlineAvailable: return "wifi.slash"
            }
        }
    }

    private var effectiveSongFilter: SongFilter {
        if songFilter == .downloaded { return .downloaded }
        if songFilter == .offlineAvailable || sourceManager.isGlobalOfflineMode {
            return .offlineAvailable
        }
        return .all
    }

    private var isLocalOnlySongFilter: Bool {
        effectiveSongFilter != .all
    }

    private var localDeviceSourceIDs: Set<String> {
        SourceManager.localDeviceSourceIDs(in: sourcesStore.sources)
    }

    init(
        sourceID: String? = nil,
        onOpenSources: (() -> Void)? = nil,
        locationRequest: Binding<SongLibraryLocationRequest?> = .constant(nil)
    ) {
        scope = sourceID.map(Scope.source) ?? .library
        self.onOpenSources = onOpenSources
        self._locationRequest = locationRequest
        let initialSortOrder = LibrarySongSortOrderPreference.load()
        _sortOrder = State(initialValue: SongSortOrder(libraryOrder: initialSortOrder))
        let initialSongFilter = UserDefaults.standard
            .string(forKey: "library.songFilter.v1")
            .flatMap(SongFilter.init(rawValue:)) ?? .all
        _songFilter = State(initialValue: initialSongFilter)
        #if os(macOS)
        let initialBrowseMode = LibrarySongBrowseModePreference.load(defaultMode: .flat)
        #else
        let initialBrowseMode = LibrarySongBrowseModePreference.load()
        #endif
        _browseMode = State(initialValue: initialBrowseMode)
        #if os(iOS)
        _presentedBrowseMode = State(initialValue: initialBrowseMode)
        #endif
    }

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

    #if os(macOS)
    private enum MacSongsViewMode: String, CaseIterable, Hashable {
        case list, compact, grid

        var title: String {
            switch self {
            case .list: return String(localized: "songs_view_list")
            case .compact: return String(localized: "songs_view_compact")
            case .grid: return String(localized: "songs_view_grid")
            }
        }

        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .compact: return "text.justify"
            case .grid: return "square.grid.3x3"
            }
        }
    }

    private enum MacSongsRowDensity: String, CaseIterable, Hashable {
        case compact, standard, relaxed

        var title: String {
            switch self {
            case .compact: return String(localized: "songs_row_compact")
            case .standard: return String(localized: "songs_row_standard")
            case .relaxed: return String(localized: "songs_row_relaxed")
            }
        }

        var icon: String {
            switch self {
            case .compact: return "chevron.up"
            case .standard: return "line.3.horizontal"
            case .relaxed: return "chevron.down"
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact: return 3
            case .standard: return 6
            case .relaxed: return 10
            }
        }
    }

    #endif

    var body: some View {
        observedContent
            // 6c U5: 目录给不出这一页(内存才排得出的排序、页内查找、目录版式、读目录失败)时占用模型,
            // 装好之前照旧转圈;页面上的编辑页(标签、歌词)在模型放掉时不丢输入。
            .songModelPage(needsArrays: !usesCatalogList && !showsCatalogList, keepsInputOnRelease: true)
            #if os(iOS)
            // 定位、目录键可能收在「⋯」系统菜单里，要问的这两句都挂在页面上。
            .filteredSongLocationAlert($filteredLocationTarget) { locateCurrentButton.locateClearingFilters($0) }
            .folderBrowseBlockerAlert(isPresented: $explainsFolderBlocker, blocker: explainedFolderBlocker,
                                      resolve: resolveFolderBrowseBlocker)
            #endif
            .environment(\.songListLocation, songLocation)
            .onChange(of: folderFollowsListSort, initial: true) { _, follows in
                folderCache.followsListSort = follows
                if follows { ensureSortedSnapshotIfNeeded() }
            }
            // Keep $sortOrder's State location stable across navigation-bar hosts.
            // A closure-backed Binding invalidates folder menus repeatedly on iOS 18.
            .onChange(of: sortOrder) { previous, requested in
                SongListPerformanceSignpost.sortSelection(
                    current: previous.rawValue,
                    requested: requested.rawValue,
                    accepted: true
                )
                LibrarySongSortOrderPreference.save(requested.libraryOrder)
                if catalogListKey != nil {
                    scheduleCatalogList(isExplicitSort: true)
                } else {
                    scheduleSortedRecompute(pruneRowModels: false, isExplicitSort: true)
                }
            }
            .onChange(of: catalogListKey, initial: true) { _, key in
                handleCatalogListKeyChange(key)
            }
            .task(id: catalogOfflineProbe) {
                await refreshCatalogOfflineState(catalogOfflineProbe)
            }
            .onChange(of: library.catalogHost?.revisions.isReadable == true, initial: true) { _, readable in
                // 目录可读时平铺列表由目录按页取:快照仓库里超出小预算的整库快照不再常驻。
                Task { await SongListSnapshotStore.shared.setCatalogServesLists(readable) }
            }
            .onChange(of: browseMode) { _, mode in
                cancelExplicitSortForNavigation()
                pendingFolderLocation = nil
                storedBrowseModeRawValue = mode.rawValue
                selection.deactivate()
                #if os(macOS)
                macFolderPath.removeAll()
                #endif
                #if os(iOS)
                scheduleBrowseModeTransition(to: mode)
                #endif
                if mode == .folder {
                    scheduleFolderIndexRecompute()
                } else {
                    folderIndexGeneration &+= 1
                    folderIndexTask?.cancel()
                    ensureSortedSnapshotIfNeeded()
                }
            }
            .onChange(of: storedBrowseModeRawValue) { _, rawValue in
                #if os(macOS)
                let storedMode = LibrarySongBrowseMode(rawValue: rawValue) ?? .flat
                #else
                let storedMode = LibrarySongBrowseMode(rawValue: rawValue) ?? .folder
                #endif
                guard storedMode != browseMode else { return }
                browseMode = storedMode
            }
            .onChange(of: searchText) { _, _ in
                pruneSelection()
                ensureSortedSnapshotIfNeeded()
            }
            .onChange(of: songFilter) { _, filter in
                UserDefaults.standard.set(filter.rawValue, forKey: "library.songFilter.v1")
                selection.deactivate()
                ensureSortedSnapshotIfNeeded()
                if requiresDownloadedSongSnapshot {
                    scheduleDownloadedFilterRefresh()
                } else {
                    downloadedFilterGeneration &+= 1
                    downloadedFilterTask?.cancel()
                    downloadedFilterTask = nil
                    isDownloadedFilterLoading = false
                }
            }
            .onChange(of: sourceManager.offlineAudioSnapshotRevision) { _, _ in
                guard requiresDownloadedSongSnapshot,
                      !isDownloadedFilterLoading else { return }
                scheduleDownloadedFilterRefresh(delay: .milliseconds(120))
            }
            .onChange(of: sourceManager.offlineModeState) { _, _ in
                ensureSortedSnapshotIfNeeded()
                if requiresDownloadedSongSnapshot {
                    scheduleDownloadedFilterRefresh()
                } else {
                    downloadedFilterGeneration &+= 1
                    downloadedFilterTask?.cancel()
                    downloadedFilterTask = nil
                    isDownloadedFilterLoading = false
                }
            }
            #if os(macOS)
            .onChange(of: tableLayout.visibleColumns) { _, columns in
                if columns.contains(.downloaded) {
                    scheduleDownloadedFilterRefresh()
                }
            }
            .onChange(of: sourceSortSignature) { _, _ in
                sortValuesVersion.invalidate(.source)
                // 目录列表的源名由目录自己跟着换(`updateCatalogSourceNames`),列表模型随之重查。
                if sortOrder.criterion == .source, !usesCatalogList {
                    scheduleSortedRecompute(
                        delay: .milliseconds(80),
                        pruneRowModels: false,
                        isExplicitSort: activeSortIsExplicit
                    )
                }
            }
            #endif
            .onChange(of: folderCache.revision) { _, _ in
                #if os(macOS)
                validateMacFolderPath()
                #endif
                pruneSelection()
                resolvePendingFolderLocation()
            }
            .onChange(of: songListVersion.replacementToken) { previousToken, token in
                let folderStructureChanged = folderReplacementChangesStructure()
                let shouldRetryPendingSort = sortRequestActive
                applyLibrarySongReplacements()
                if folderStructureChanged {
                    folderSourceRevision &+= 1
                    scheduleFolderIndexRecompute(delay: .milliseconds(80))
                } else {
                    carryReusableFolderIndex(from: previousToken, to: token)
                }
                let technicalOrderNeedsRefresh: Bool = switch sortOrder.criterion {
                case .fileName, .dateAdded, .sourceDate, .duration, .serverPlayCount, .year,
                        .bitRate, .bitDepth:
                    true
                case .title, .artist, .album, .format, .playCount, .source, .downloaded:
                    false
                }
                if requiresSortedSnapshot,
                   listCache.isEmpty
                    || shouldRetryPendingSort
                    || technicalOrderNeedsRefresh {
                    scheduleSortedRecompute(
                        delay: .milliseconds(80),
                        pruneRowModels: false,
                        isExplicitSort: activeSortIsExplicit
                    )
                }
            }
            .onChange(of: songListInvalidationRevision) { _, _ in
                guard requiresSortedSnapshot else { return }
                scheduleSortedRecompute(
                    delay: .milliseconds(80),
                    pruneRowModels: false,
                    isExplicitSort: activeSortIsExplicit
                )
            }
            .background {
                SongSelectionActivationObserver(selection: selection) {
                    cancelExplicitSortForSelection()
                }
            }
            .background {
                SongListCatalogSelectionObserver(selection: selection, catalogList: catalogList)
            }
            .onDisappear(perform: handleViewDisappear)
            #if os(iOS)
            .navigationDestination(item: $folderLocationDestination) { destination in
                LibraryFolderNodeView(
                    nodeID: destination.nodeID,
                    folderCache: folderCache,
                    listCache: listCache,
                    selection: selection,
                    sortOrder: $sortOrder,
                    initialLocation: destination.song
                )
            }
            #endif
            .sheet(isPresented: $showsHomeFolders) {
                NavigationStack {
                    HomeFolderManagementView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("done") { showsHomeFolders = false }
                            }
                        }
                }
            }
            #if os(macOS)
            .sheet(isPresented: $showAddVisibleToPlaylist) {
                BatchAddToPlaylistSheet(songs: showsCatalogList ? catalogBatchSongs : filteredSongs.filteredPlayable())
            }
            .sheet(item: $contextAddToPlaylistSong) { song in
                AddToPlaylistSheet(song: library.song(id: song.id) ?? song)
            }
            .sheet(item: $contextSongInfoSong) { song in
                SongInfoSheet(song: library.song(id: song.id) ?? song)
            }
            .sheet(item: $contextTagEditorSong) { song in
                TagEditorView(song: library.song(id: song.id) ?? song) { updated in
                    player.syncSongMetadata(updated)
                    player.forceRefreshNowPlayingArtwork()
                }
            }
            .sheet(item: $contextShareSong) { song in
                SongShareSheet(song: library.song(id: song.id) ?? song)
            }
            .sheet(item: $contextPlaybackRangeRequest) { request in
                SongPlaybackRangeEditor(
                    song: library.song(id: request.song.id) ?? request.song,
                    purpose: request.purpose
                )
            }
            .macSongActionHost(contextSongAction)
            .alert("songs_export_failed",
                   isPresented: exportErrorPresentation) {
                Button("done", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            #endif
            .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
    }

    private var observedContent: some View {
        content
            .songBatchActions(
                selection: selection,
                context: batchActionContext,
                orderedIDs: { batchOrderedSongIDs },
                resolve: { library.unobservedVisibleSong(id: $0) }
            )
            .onAppear {
                // 目录列表的多选 id 取好后,已选里不在列表上的去掉(同 `pruneSelection`)。
                let selectionModel = selection
                catalogList.selectionIDsDidLoad = { ids in
                    guard selectionModel.isActive, !selectionModel.isEmpty else { return }
                    selectionModel.prune(to: Set(ids))
                }
                // NavigationStack keeps this destination alive while another
                // tab is selected. Reuse its existing order instead of
                // sorting 10K songs again on every return.
                ensureSortedSnapshotIfNeeded()
                if !publishReusableFolderIndex() {
                    scheduleFolderIndexRecompute()
                }
                if requiresDownloadedSongSnapshot {
                    scheduleDownloadedFilterRefresh()
                }
                handleLocationRequest(locationRequest)
            }
            .onChange(of: locationRequest) { _, request in
                handleLocationRequest(request)
            }
            .onChange(of: songListVersion.collectionRevision) { _, _ in
                if requiresSortedSnapshot {
                    scheduleSortedRecompute(
                        delay: .milliseconds(180),
                        pruneRowModels: true
                    )
                } else if !listCache.isEmpty {
                    listCache = SongListCache()
                }
                scheduleFolderIndexRecompute(delay: .milliseconds(180))
                if requiresDownloadedSongSnapshot {
                    scheduleDownloadedFilterRefresh(delay: .milliseconds(180))
                }
            }
            .onChange(of: configuredFolderSourceDescriptors) { _, _ in
                folderSourceRevision &+= 1
                scheduleFolderIndexRecompute(delay: .milliseconds(80))
            }
            .onChange(of: library.catalogHost?.revisions.membership) { _, _ in
                // 目录版式的索引按目录建:目录比内存晚一拍,目录跟上(歌入了目录)再建一次。
                guard library.readableCatalogReader != nil else { return }
                scheduleFolderIndexRecompute(delay: .milliseconds(180))
            }
            .onChange(of: scanService.folderHierarchyRevision) { _, _ in
                folderSourceRevision &+= 1
                scheduleFolderIndexRecompute(delay: .milliseconds(80))
                sortValuesVersion.invalidate(.fileName)
                // 目录列表的文件名索引由目录自己跟着换(`updateCatalogFileNameIndexes`)。
                if sortOrder.criterion == .fileName, !usesCatalogList {
                    scheduleSortedRecompute(delay: .milliseconds(80), pruneRowModels: false,
                                            isExplicitSort: activeSortIsExplicit)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: CloudDirectoryNameStore.didChangeNotification
                )
            ) { notification in
                guard let sourceID = notification.object as? String,
                      configuredFolderSourceDescriptors.contains(where: {
                          $0.sourceID == sourceID
                      }) else { return }
                folderSourceRevision &+= 1
                scheduleFolderIndexRecompute(delay: .milliseconds(80))
            }
            .onChange(of: library.playlistCollectionRevision) { _, _ in
                scheduleFolderIndexRecompute(delay: .milliseconds(80))
            }
    }

    private func handleViewDisappear() {
        cancelExplicitSortForNavigation()
        songLocation.cancel()
        pendingFolderLocation = nil
        downloadedFilterGeneration &+= 1
        downloadedFilterTask?.cancel()
        downloadedFilterTask = nil
        isDownloadedFilterLoading = false
        #if os(iOS)
        browseModeTransitionTask?.cancel()
        browseModeTransitionTask = nil
        isBrowseModeTransitioning = false
        #endif
    }

    #if os(macOS)
    private var exportErrorPresentation: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { isPresented in
                if !isPresented {
                    exportError = nil
                }
            }
        )
    }
    #endif

    private var sourceSongListState: LibrarySourceSongListState? {
        guard case .source(let sourceID) = scope else { return nil }
        return library.sourceSongListState(for: sourceID)
    }

    private var songListVersion: SongListSnapshotVersion {
        sourceSongListState?.version ?? SongListSnapshotVersion(
            collectionRevision: library.visibleSongCollectionRevision,
            replacementToken: library.songReplacementToken
        )
    }

    private var songListInvalidationRevision: UInt64 {
        sourceSongListState?.sortInvalidationRevision ?? library.songListSnapshotInvalidationRevision
    }

    private var replacedSongIDs: Set<String> {
        sourceSongListState?.replacedSongIDs ?? library.lastReplacedSongIDs
    }

    private var songs: [Song] {
        scope.songs(in: library, sources: sourcesStore)
    }

    // MARK: Catalog-backed flat list (P2a)

    /// 目录给得出这一页、而且眼前是平铺的整份列表(不在目录版式、没有「已下载」、没有页内查找)。
    /// 排序是否支持另算(`usesCatalogList`)。
    private var catalogEligibleIgnoringOrder: Bool {
        library.catalogHost?.revisions.isReadable == true
            && !showsFolderBrowser
            && (effectiveSongFilter == .all || (effectiveSongFilter == .downloaded && catalogOfflineIsCurrent))
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 目录给得出与内存路径一样结果的排序:P2a 的那些,外加离线状态补全后的「已下载」。
    private func catalogSupports(_ order: LibrarySongSortOrder) -> Bool {
        SongListCatalogPolicy.supports(order) || (order.criterion == .downloaded && catalogOfflineIsCurrent)
    }

    /// 平铺列表的「已下载」筛选与排序由目录给(不再为它在内存里探测整库的离线状态)。
    private var catalogServesDownloadedState: Bool {
        usesCatalogList && (effectiveSongFilter == .downloaded || sortOrder.criterion == .downloaded)
    }

    /// 什么时候重新问一次目录里的离线状态是不是当前的。
    private struct CatalogOfflineProbe: Equatable {
        let readable: Bool
        let everything: UInt64
        let filter: SongFilter
        let criterion: LibrarySongSortCriterion
    }

    private var catalogOfflineProbe: CatalogOfflineProbe {
        CatalogOfflineProbe(
            readable: library.catalogHost?.revisions.isReadable == true,
            everything: library.catalogHost?.revisions.everything ?? 0,
            filter: effectiveSongFilter,
            criterion: sortOrder.criterion
        )
    }

    private func refreshCatalogOfflineState(_ probe: CatalogOfflineProbe) async {
        // 目录一可读就问,不等用户切到「已下载」:先走一遍内存路径就会先把整库的离线状态探测一遍。
        guard probe.readable, let reader = library.readableCatalogReader else {
            if !probe.readable, catalogOfflineIsCurrent { catalogOfflineIsCurrent = false }
            return
        }
        let current: Bool
        do {
            current = try await reader.offlineStateIsCurrent()
        } catch {
            plog("📚 catalog offline state probe failed: \(error)")
            current = false
        }
        guard !Task.isCancelled, catalogOfflineIsCurrent != current else { return }
        catalogOfflineIsCurrent = current
    }

    /// 平铺列表直接从曲库目录按页取,不在内存里排整库。查找、「已下载」、目录版式,以及目录
    /// 还给不出一样结果的排序(`SongListCatalogPolicy`)照旧走内存;目录读失败的那个键也走内存。
    private var usesCatalogList: Bool {
        guard catalogEligibleIgnoringOrder, catalogSupports(sortOrder.libraryOrder) else { return false }
        return catalogList.failedKey != catalogListKeyIgnoringFailure
    }

    private var catalogListKey: SongListCatalogList.Key? {
        usesCatalogList ? catalogListKeyIgnoringFailure : nil
    }

    private var catalogListKeyIgnoringFailure: SongListCatalogList.Key {
        let base = catalogBaseScope
        var listScope = base
        #if os(macOS)
        // Mac 的来源筛选条:列表只要那一个源,页头与筛选条上的计数仍按整页。
        if let selectedSourceID { listScope.sourceID = selectedSourceID }
        #endif
        // 「已下载」只筛列表;整页的计数(空状态、来源筛选条)仍按整页。
        listScope.downloadedOnly = effectiveSongFilter == .downloaded
        return SongListCatalogList.Key(order: sortOrder.libraryOrder, scope: listScope, baseScope: base)
    }

    /// 与 `Scope.songs(in:sources:)` 同一个范围:整库是可见音乐;单个源是这个源的可见歌曲去掉
    /// 有声与环境音(只因歌单镜像在库里的条目留着),Audiobookshelf 源全留。
    private var catalogBaseScope: LibrarySongScope {
        switch scope {
        case .library:
            return .visibleMusic
        case .source(let sourceID):
            if scope.showsAudiobookshelfContents(in: sourcesStore) {
                return LibrarySongScope(sourceID: sourceID)
            }
            return LibrarySongScope(kinds: [.music, .collectionOnly], sourceID: sourceID)
        }
    }

    /// 眼前画的是目录列表。手里没有内存快照时一律画目录那一份(换排序时新的取好之前先留着旧的;
    /// 换到内存才排得出的排序时,内存快照排好之前也先留着它);有内存快照时,目录那一份正好是
    /// 当前的排序与范围才换过去。
    private var showsCatalogList: Bool {
        guard catalogList.hasCurrent, catalogEligibleIgnoringOrder else { return false }
        if listCache.isEmpty { return true }
        return usesCatalogList && catalogList.currentKey == catalogListKey
    }

    /// 整页范围是空的(给整页空状态)。目录路径计数还没取到时不算空。
    private var showsEmptyLibrary: Bool {
        if showsFolderBrowser { return false }
        if usesCatalogList || showsCatalogList {
            return catalogList.baseCount == 0
        }
        // 模型不在内存里时整库数组是空的,不是「没有歌」(这时页面在等模型,见 `isPreparingList`)。
        return library.isReady && songs.isEmpty
    }

    /// 眼前这份列表里可播放的歌数(页头、工具栏的播放与随机键)。
    private var displayedPlayableCount: Int {
        showsCatalogList ? catalogList.listPlayableCount : filteredProjection.playableCount
    }

    /// 多选、范围选择要的「这份列表的 id」。目录列表的在多选开始时取一次。
    private var selectableOrderedSongIDs: [String] {
        showsCatalogList ? (catalogList.selectionIDs ?? []) : filteredSongIDs
    }

    private func handleCatalogListKeyChange(_ key: SongListCatalogList.Key?) {
        guard key != nil else {
            catalogList.cancelPending()
            if library.catalogHost?.revisions.isReadable != true, catalogList.hasCurrent {
                catalogList.reset()
            }
            if !sortRequestActive { ensureSortedSnapshotIfNeeded() }
            return
        }
        scheduleCatalogList(isExplicitSort: false)
    }

    /// 让目录那一份列表跟上当前的排序与范围。换上之前旧的那一份(或内存快照)照旧显示;
    /// 用户换排序时带着与内存路径同样的进度提示。
    private func scheduleCatalogList(isExplicitSort: Bool) {
        guard let key = catalogListKey, let host = library.catalogHost else { return }
        if !isExplicitSort, catalogList.isCurrentOrPending(key) { return }
        if !isExplicitSort, let explicitGeneration = sortProgress.generation {
            sortFeedbackTask?.cancel()
            sortFeedbackTask = nil
            sortFeedbackDeadline = nil
            let cancelledOrder = sortProgress.order ?? sortOrder.libraryOrder
            _ = sortProgress.cancel(generation: explicitGeneration)
            SongListPerformanceSignpost.sortCancelled(
                generation: explicitGeneration,
                order: cancelledOrder.rawValue
            )
        }
        sortGeneration &+= 1
        let generation = sortGeneration
        let order = key.order
        pendingSnapshot = nil
        pendingSnapshotPrunesRows = false
        pendingSnapshotIsExplicitSort = false
        pendingSnapshotGeneration = 0
        pendingSnapshotOrder = nil
        activeSortIsExplicit = isExplicitSort
        sortRequestActive = true
        if isExplicitSort {
            beginSortFeedback(generation: generation, order: order)
        }
        sortTask?.cancel()
        sortTask = Task { @MainActor in
            let ready = await catalogList.prepare(key: key, host: host)
            guard !Task.isCancelled, sortGeneration == generation else { return }
            if ready, usesCatalogList, !listCache.isEmpty {
                // 目录那一份换上了:内存里的整库快照不再需要,放掉。
                listCache = SongListCache()
            }
            if ready, usesCatalogList {
                // 快照仓库里这一页的那几份也不再需要(与 `listCache` 是同一个对象,这里放掉最后一个引用)。
                let scopeKey = scope.snapshotCacheKey
                Task { await SongListSnapshotStore.shared.releaseCachedSnapshots(scopeKey: scopeKey) }
            }
            if isExplicitSort {
                if ready {
                    finishSortAfterPublication(generation: generation, order: order)
                } else {
                    finishSortWithoutPublication(generation: generation, order: order, isExplicitSort: true)
                }
            } else {
                sortRequestActive = false
                activeSortIsExplicit = false
            }
            // 目录读失败时 `failedKey` 让 `catalogListKey` 变成 nil,`handleCatalogListKeyChange`
            // 接着排内存快照。
        }
    }

    /// 目录列表上的动作要整份 id:按显示顺序取好再做(播放、加入队列、导出)。
    private func withCatalogSongIDs(_ body: @escaping @MainActor ([String]) -> Void) {
        Task { @MainActor in
            guard let ids = await catalogList.orderedSongIDs(), !ids.isEmpty else { return }
            body(ids)
        }
    }

    private var requiresDownloadedSongSnapshot: Bool {
        #if os(macOS)
        (isLocalOnlySongFilter && !catalogServesDownloadedState)
            || tableLayout.visibleColumns.contains(.downloaded)
            || (sortOrder.criterion == .downloaded && !catalogServesDownloadedState)
        #else
        isLocalOnlySongFilter && !catalogServesDownloadedState
        #endif
    }

    private var songListSortValues: SongListSortValues {
        #if os(macOS)
        var fileNameIndexes: [String: SourceSyncIndex] = [:]
        if sortOrder.criterion == .fileName {
            for source in sourcesStore.allSources where !source.type.itemPathsCarryFileNames {
                if case .source(let id) = scope, id != source.id { continue }
                fileNameIndexes[source.id] = source.type.usesOpaqueDirectoryIdentifiers || source.type == .fnMusic
                    ? scanService.libraryFolderSyncIndex(for: source.id) : SourceSyncIndex()
            }
        }
        return SongListSortValues(
            playCountsBySongID: playCountsBySongID,
            downloadedSongIDs: downloadedSongIDs,
            sourceNamesByID: Dictionary(uniqueKeysWithValues: sourcesStore.sources.map {
                ($0.id, $0.name)
            }),
            fileNameIndexesBySourceID: fileNameIndexes
        )
        #else
        .empty
        #endif
    }

    #if os(macOS)
    private var sourceSortSignature: [String] {
        sourcesStore.sources
            .map { "\($0.id)\u{0}\($0.name)" }
            .sorted()
    }
    #endif

    private func localizedSortLabel(_ order: LibrarySongSortOrder) -> String {
        SongSortOrder(libraryOrder: order).label
    }

    private func sortProgressMessage(for order: LibrarySongSortOrder) -> String {
        String(
            format: String(localized: "song_sort_progress_format"),
            localizedSortLabel(order)
        )
    }

    private func sortCompletedMessage(for order: LibrarySongSortOrder) -> String {
        String(
            format: String(localized: "song_sort_progress_complete_format"),
            localizedSortLabel(order)
        )
    }

    private var showsFolderBrowser: Bool {
        browseMode == .folder && folderBrowseBlocker == nil
    }

    /// 开着「已下载」或页内查找有字时目录出不来，歌照平铺列出。
    private var folderBrowseBlocker: LibraryFolderBrowseBlocker? {
        if isLocalOnlySongFilter { return .downloadedFilter }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .search }
        return nil
    }

    /// 版式键说明框里的一键解决：关掉「已下载」、清空查找，切到目录。
    private func resolveFolderBrowseBlocker() {
        searchText = ""
        songFilter = .all
        browseMode = .folder
    }

    /// 目录被挡住时点了「目录」：弹说明（挂在页面上）。
    private func explainFolderBrowseBlocker(_ blocker: LibraryFolderBrowseBlocker) {
        explainedFolderBlocker = blocker
        explainsFolderBlocker = true
    }

    private var folderRootSourceID: String? {
        guard case .source(let sourceID) = scope else { return nil }
        return sourceID
    }

    private var configuredFolderSourceDescriptors: [LibraryFolderSourceDescriptor] {
        let descriptors = sourcesStore.allSources.map(LibraryFolderSourceDescriptor.init(source:))
        guard case .source(let sourceID) = scope else { return descriptors }
        return descriptors.filter { $0.sourceID == sourceID }
    }

    @ViewBuilder
    private var content: some View {
        if showsEmptyLibrary {
            if case .source(let sourceID) = scope, let source = sourcesStore.source(id: sourceID) {
                EmptyStateView(
                    // 源名是用户起的: 用插值传进去(键是 "%@"), 不拿它当本地化键去查, 也不按 Markdown 解析。
                    titleKey: "\(source.name)",
                    descriptionKey: "source_empty_desc",
                    systemImage: source.type.iconName,
                    actionLabel: onOpenSources == nil ? nil : "sources_manage_action",
                    action: onOpenSources
                )
            } else {
                EmptyStateView(
                    titleKey: "no_songs",
                    descriptionKey: "no_songs_desc",
                    systemImage: "music.note"
                )
            }
        } else {
            #if os(iOS)
            // 工具栏、页内查找和极简页头挂在转圈与列表共同的这一层：推入的第一帧（列表还在排序，或刚从
            // 缓存摆上）就带着它们，换成列表时也不动。挂在列表上时第一帧还是转圈，导航栏要等推入动画走完
            // 才补上按钮和查找框。页头要挂在查找框外面，才排在它上面。
            preparedContent
                .toolbar {
                    iosToolbar
                }
                .libraryPageFind(text: $searchText, prompt: "filter_songs_placeholder")
                .minimalPageHeader { minimalHeader }
            #else
            preparedContent
            #endif
        }
    }

    /// 排序、分目录还没好：先转圈，好了换成列表。
    private var isPreparingList: Bool {
        if showsCatalogList { return false }
        // 内存路径而模型不在内存里:等它装回来(页面替自己占用了)。
        if !usesCatalogList, !library.isReady { return true }
        // 目录那一份第一次取行号还没回来,手里也没有内存快照。
        if usesCatalogList { return listCache.isEmpty }
        return (!songs.isEmpty && requiresSortedSnapshot && listCache.isEmpty)
            || (showsFolderBrowser && !folderCache.hasIndex)
    }

    @ViewBuilder
    private var preparedContent: some View {
        if isPreparingList {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pmAppearFade(.contentAppear)
                #if os(iOS) && DEBUG
                .onAppear { LibrarySectionSwitchTrace.mark("songs loading") }
                #endif
        } else {
            // 成对分支各自淡入，不做交叉淡入：转圈与整张表要是在过渡期同时留在布局里，
            // 会先把彼此顶开再弹回。切换点也不包动画事务。
            #if os(macOS)
            macSongList
                .pmAppearFade(.contentAppear)
                #if DEBUG
                .onAppear { MacRouteTiming.mark("songs content") }
                #endif
            #else
            iosSongList
                .pmAppearFade(.contentAppear)
                #if DEBUG
                .onAppear { LibrarySectionSwitchTrace.mark("songs content") }
                #endif
            #endif
        }
    }

    #if os(iOS)
    /// 极简模式根页没有导航栏：工具栏里的这些操作排成页头。还在排序、分目录时就是列表出来后的那个页头，
    /// 只是播放键先不能点，数量先按整库的歌数写（筛了「已下载」时先空着），换成列表时这一行不动。
    private var minimalHeader: SongListMinimalHeader {
        let isPreparing = isPreparingList
        let preparingTotal: Int? = usesCatalogList ? catalogList.baseCount : songs.count
        let preparingCount = effectiveSongFilter == .all
            ? preparingTotal.map { LibraryCountText.formattedSongs($0) } ?? " "
            : " "
        return SongListMinimalHeader(
            selection: selection,
            progress: sortProgress,
            countText: isPreparing ? preparingCount : songCountText,
            canPlay: !isPreparing && !showsFolderBrowser && displayedPlayableCount > 0,
            canShuffle: !isPreparing && !showsFolderBrowser && displayedPlayableCount > 1,
            browseMode: $browseMode,
            folderBlocker: folderBrowseBlocker,
            explainFolderBlocker: explainFolderBrowseBlocker,
            sortOrder: $sortOrder,
            filter: $songFilter,
            manageHomeFolders: showsFolderBrowser ? { showsHomeFolders = true } : nil,
            folderFollowsListSort: showsFolderBrowser ? $folderFollowsListSort : nil,
            orderedIDs: { isPreparing ? [] : batchOrderedSongIDs },
            onPlay: playVisibleSongs,
            onShuffle: shuffleVisibleSongs
        )
    }
    #endif

    #if os(iOS)
    private var iosSongList: some View {
        ZStack {
            Group {
                if presentedShowsFolderBrowser {
                    LibraryFolderRootView(
                        folderCache: folderCache,
                        listCache: listCache,
                        rootSourceID: folderRootSourceID,
                        selection: selection,
                        sortOrder: $sortOrder,
                        showsListeningIntents: showsListeningIntentShelf
                    )
                } else if showsCatalogList, effectiveSongFilter == .downloaded, usesCatalogList,
                          catalogList.currentKey == catalogListKey, catalogList.count == 0 {
                    ContentUnavailableView(
                        "filter_downloaded",
                        systemImage: "arrow.down.circle",
                        description: Text("filter_downloaded_empty_desc")
                    )
                } else if showsCatalogList {
                    IOSCatalogSongListContainer(
                        catalog: catalogList,
                        rowRevision: catalogList.rowRevision,
                        sectionIndexEntries: catalogList.sections,
                        locatedSongID: locatedSongID,
                        locationRequestID: songLocation.request?.id,
                        selection: selection,
                        showsListeningIntents: showsListeningIntentShelf,
                        onPlay: playSong
                    )
                    .equatable()
                } else if isLocalOnlySongFilter,
                          isDownloadedFilterLoading,
                          downloadedSongIDs.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("filter_downloaded_loading")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !projectionQuery.isEmpty, filteredRows.isEmpty {
                    ContentUnavailableView.search(text: projectionQuery)
                } else if isLocalOnlySongFilter, filteredRows.isEmpty {
                    ContentUnavailableView(
                        LocalizedStringKey(effectiveSongFilter == .offlineAvailable ? "filter_offline_available" : "filter_downloaded"),
                        systemImage: effectiveSongFilter == .offlineAvailable ? "wifi.slash" : "arrow.down.circle",
                        description: Text(
                            LocalizedStringKey(
                                effectiveSongFilter == .offlineAvailable
                                    ? "filter_offline_available_empty_desc"
                                    : "filter_downloaded_empty_desc"
                            )
                        )
                    )
                } else {
                    if isLocalOnlySongFilter || !projectionQuery.isEmpty {
                        IOSSongListFilteredContainer(
                            projection: filteredProjection,
                            projectionRevision: downloadedFilterRevision,
                            query: projectionQuery,
                            rowOrderRevision: listCache.rowOrderRevision,
                            cache: listCache,
                            selection: selection,
                            onPlay: playSong
                        )
                        .equatable()
                        .songLocationReader(songLocation, revision: listCache.rowOrderRevision)
                    } else {
                        IOSSongListContainer(
                            cache: listCache,
                            rowOrderRevision: listCache.rowOrderRevision,
                            sectionIndexEntries: listCache.sectionIndexEntries,
                            locatedSongID: locatedSongID,
                            locationRequestID: songLocation.request?.id,
                            selection: selection,
                            showsListeningIntents: showsListeningIntentShelf,
                            onPlay: playSong
                        )
                        .equatable()
                    }
                }
            }
            .allowsHitTesting(!isBrowseModeTransitioning)

            if isBrowseModeTransitioning {
                SongBrowseModeTransitionOverlay(mode: browseMode)
                    .transition(.opacity)
            }
        }
        .pmAnimation(.control, value: isBrowseModeTransitioning)
        .onScrollPhaseChange { _, newPhase in
            updateListInteraction(for: newPhase)
        }
        .modifier(SongListAppearancePreference())
        #if DEBUG
        // 截图用：`PRIMUSE_DEBUG_EDIT=songs` 打开歌曲页就进多选（看多选态的页头与底栏）。
        .task {
            guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_EDIT"] == "songs" else { return }
            try? await Task.sleep(for: .seconds(2))
            selection.activate()
        }
        #endif
        .task(id: searchText) {
            // 清空立刻生效; 输入时等停手再过滤。
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            appliedSearchText = searchText
        }
    }

    /// 页头上的「8,426 首歌曲」：眼前这份列表有几首（筛选、查找之后的）。
    private var songCountText: String {
        let count = showsCatalogList
            ? catalogList.count
            : showsFolderBrowser && listCache.isEmpty
                ? songs.count
                : filteredProjection.rows.count
        return LibraryCountText.formattedSongs(count)
    }

    /// 只在整个歌曲页、没在筛选、没在多选时出现。
    private var showsListeningIntentShelf: Bool {
        showsListeningIntentsSetting
            && effectiveSongFilter == .all
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selection.isActive
    }

    private var presentedShowsFolderBrowser: Bool {
        presentedBrowseMode == .folder && folderBrowseBlocker == nil
    }

    private func scheduleBrowseModeTransition(to mode: LibrarySongBrowseMode) {
        browseModeTransitionTask?.cancel()
        isBrowseModeTransitioning = true

        browseModeTransitionTask = Task { @MainActor in
            // Publish the progress layer before SwiftUI has to attach the
            // large flat List. This guarantees visible feedback even when the
            // first layout pass for a very large library occupies the main
            // thread for longer than a frame.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, browseMode == mode else { return }

            presentedBrowseMode = mode
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, browseMode == mode else { return }
            isBrowseModeTransitioning = false
            browseModeTransitionTask = nil
        }
    }
    #endif

    #if os(macOS)
    private func openMacFolder(_ nodeID: LibraryFolderNodeID) {
        let path = resolvedMacFolderPath(to: nodeID)
        guard !path.isEmpty else { return }
        if macFolderPath != path { songLocation = SongListLocation() }
        selection.deactivate()
        pmWithAnimation(.list) {
            macFolderPath = path
        }
    }

    private func navigateMacFolder(to nodeID: LibraryFolderNodeID?) {
        songLocation = SongListLocation()
        selection.deactivate()
        pmWithAnimation(.list) {
            guard let nodeID else {
                macFolderPath.removeAll()
                return
            }
            if let index = macFolderPath.firstIndex(of: nodeID) {
                macFolderPath = Array(macFolderPath.prefix(through: index))
            } else {
                macFolderPath = resolvedMacFolderPath(to: nodeID)
            }
        }
    }

    private func resolvedMacFolderPath(
        to nodeID: LibraryFolderNodeID
    ) -> [LibraryFolderNodeID] {
        let rootIDs = Set(folderCache.rootNodes(sourceID: folderRootSourceID).map(\.id))
        guard !rootIDs.isEmpty else { return [] }

        var reversedPath: [LibraryFolderNodeID] = []
        var visited: Set<LibraryFolderNodeID> = []
        var cursor: LibraryFolderNodeID? = nodeID
        var reachedVisibleRoot = false

        while let currentID = cursor,
              visited.insert(currentID).inserted,
              let node = folderCache.node(withID: currentID) {
            reversedPath.append(currentID)
            if rootIDs.contains(currentID) {
                reachedVisibleRoot = true
                break
            }
            cursor = node.parentID
        }

        guard reachedVisibleRoot else { return [] }
        return Array(reversedPath.reversed())
    }

    private func validateMacFolderPath() {
        guard let nodeID = macFolderPath.last else { return }
        let resolvedPath = resolvedMacFolderPath(to: nodeID)
        guard resolvedPath != macFolderPath else { return }
        selection.deactivate()
        macFolderPath = resolvedPath
    }

    private var macSongList: some View {
        let rows = filteredRows
        let usesCatalogRows = showsCatalogList
        let catalogLocateKey = SongListCatalogLocateKey(
            songID: usesCatalogRows ? locatedSongID : nil,
            rowRevision: catalogList.rowRevision
        )
        let locatedRowOffset: Int?
        if usesCatalogRows {
            locatedRowOffset = catalogLocatedRow.flatMap { $0.key == catalogLocateKey ? $0.position : nil }
        } else {
            locatedRowOffset = locatedSongID.flatMap { songID in
                rows.firstIndex(where: { $0.id == songID })
            }
        }
        let scrollTarget = (songLocation.needsScroll ? locatedRowOffset : nil).map { offset in
            switch macViewMode {
            case .list, .compact:
                MacSongLocationScrollTarget.windowedRow(
                    offset: offset,
                    rowHeight: macVirtualRowHeight
                )
            case .grid:
                MacSongLocationScrollTarget.element(offset)
            }
        }
        let scrollResetKey = [
            scope.snapshotCacheKey,
            songFilter.rawValue,
            searchText,
            browseMode.rawValue,
            macViewMode.rawValue,
            macRowDensity.rawValue,
        ].joined(separator: "\u{1F}")
        let request = MacSongLocationScrollRequest(
            requestID: songLocation.request?.id,
            songID: locatedSongID,
            rowOrderRevision: usesCatalogRows ? catalogList.rowRevision : listCache.rowOrderRevision,
            target: scrollTarget,
            rowCount: usesCatalogRows ? catalogList.count : rows.count,
            resetKey: scrollResetKey
        )

        return VStack(alignment: .leading, spacing: 0) {
            macPinnedSongListChrome

            Group {
                if showsFolderBrowser {
                    // 分支切换本身就重建，淡入只动透明度：既不把重建放进动画事务，
                    // 也不会给下面的虚拟化滚动面留下声明式动画。
                    macFolderSongList
                        .pmAppearFade()
                } else if usesCatalogRows {
                    macCatalogFlatSongList(request: request)
                        .pmAppearFade()
                } else {
                    macFlatSongList(rows: rows, request: request)
                        .pmAppearFade()
                }
            }
            .onScrollPhaseChange { _, newPhase in
                updateListInteraction(for: newPhase)
            }
        }
        .background(PMColor.bg.ignoresSafeArea())
        // 目录列表的定位:按行号查出那首在第几行,再交给滚动面。
        .task(id: catalogLocateKey) {
            guard let songID = catalogLocateKey.songID else { return }
            let position = await catalogList.position(of: songID)
            guard !Task.isCancelled else { return }
            catalogLocatedRow = position.map { SongListCatalogLocatedRow(key: catalogLocateKey, position: $0) }
        }
        .onAppear { rebuildPlayCounts() }
        .onChange(of: selectedSourceID) { _, _ in
            pruneSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            rebuildPlayCounts()
        }
    }

    private func macFlatSongList(
        rows: [SongListRowIdentity],
        request: MacSongLocationScrollRequest
    ) -> some View {
        let rowHeight: CGFloat? = macViewMode == .grid ? nil : macVirtualRowHeight
        let ordinalWidth = MacOrdinalColumn.width(
            for: rows.count, minimum: 32, fontSize: 11, locale: locale, showsNumbers: showsRowNumbers
        )
        return MacSongScrollSurface(
            allowsHorizontalScrolling: macViewMode == .list,
            rowCount: rows.count,
            rowHeight: rowHeight,
            request: request
        ) {
            macSongScrollChrome(isEmpty: rows.isEmpty, ordinalWidth: ordinalWidth)
        } results: { range, viewportWidth in
            macFlatSongResults(
                rows: rows,
                range: range,
                viewportWidth: viewportWidth,
                ordinalWidth: ordinalWidth
            )
        }
    }

    private func macFlatSongResults(
        rows: [SongListRowIdentity],
        range: Range<Int>,
        viewportWidth: CGFloat,
        ordinalWidth: CGFloat
    ) -> some View {
        Group {
            switch macViewMode {
            case .list, .compact:
                macWindowedSongResults(
                    rows: rows,
                    range: range,
                    viewportWidth: viewportWidth,
                    ordinalWidth: ordinalWidth
                )
                .pmAppearFade()
            case .grid:
                songGrid(rows: rows)
                    .frame(
                        width: max(0, viewportWidth - PMSpace.xxxl * 2),
                        alignment: .leading
                    )
                    .padding(.horizontal, PMSpace.xxxl)
                    .pmAppearFade()
            }
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
    }

    private func macWindowedSongResults(
        rows: [SongListRowIdentity],
        range: Range<Int>,
        viewportWidth: CGFloat,
        ordinalWidth: CGFloat
    ) -> some View {
        let rowHeight = macVirtualRowHeight
        let rowWidth = max(0, viewportWidth - PMSpace.xxxl * 2)
        let columns = activeTableColumns
        let columnWidths = Dictionary(uniqueKeysWithValues: columns.map { ($0, columnWidth($0)) })
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: CGFloat(range.lowerBound) * rowHeight)
                .frame(minWidth: viewportWidth, alignment: .leading)
                .accessibilityHidden(true)

            ForEach(range, id: \.self) { position in
                let row = rows[position]
                Group {
                    if let song = library.unobservedVisibleSong(id: row.id) {
                        Group {
                            switch macViewMode {
                            case .list:
                                songTableRow(song, index: row.offset, ordinalWidth: ordinalWidth, columns: columns, columnWidths: columnWidths)
                            case .compact:
                                compactSongRow(song, index: row.offset, ordinalWidth: ordinalWidth)
                            case .grid:
                                EmptyView()
                            }
                        }
                        .songSelectable(
                            songID: row.id,
                            selection: selection,
                            orderedIDs: { filteredSongIDs },
                            defaultAction: { playSong(song) }
                        )
                    } else {
                        Color.clear
                    }
                }
                .id(position)
                .frame(minWidth: rowWidth, alignment: .leading)
                .frame(height: rowHeight)
                .padding(.horizontal, PMSpace.xxxl)
            }

            Color.clear
                .frame(height: CGFloat(rows.count - range.upperBound) * rowHeight)
                .frame(minWidth: viewportWidth, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
    }

    // MARK: Mac catalog-backed flat list (P2a)

    /// 目录列表版的 `macFlatSongList`:行数来自目录,行按位置从当前那一份按页取,
    /// 还没取到的位置留空(与内存路径里解析不到歌的位置一样)。
    private func macCatalogFlatSongList(request: MacSongLocationScrollRequest) -> some View {
        let rowCount = catalogList.count
        let rowHeight: CGFloat? = macViewMode == .grid ? nil : macVirtualRowHeight
        let ordinalWidth = MacOrdinalColumn.width(
            for: rowCount, minimum: 32, fontSize: 11, locale: locale, showsNumbers: showsRowNumbers
        )
        return MacSongScrollSurface(
            allowsHorizontalScrolling: macViewMode == .list,
            rowCount: rowCount,
            rowHeight: rowHeight,
            request: request
        ) {
            macSongScrollChrome(isEmpty: rowCount == 0, ordinalWidth: ordinalWidth)
        } results: { range, viewportWidth in
            macCatalogFlatSongResults(
                rowCount: rowCount,
                range: range,
                viewportWidth: viewportWidth,
                ordinalWidth: ordinalWidth
            )
        }
    }

    private func macCatalogFlatSongResults(
        rowCount: Int,
        range: Range<Int>,
        viewportWidth: CGFloat,
        ordinalWidth: CGFloat
    ) -> some View {
        Group {
            switch macViewMode {
            case .list, .compact:
                macCatalogWindowedSongResults(
                    rowCount: rowCount,
                    range: range,
                    viewportWidth: viewportWidth,
                    ordinalWidth: ordinalWidth
                )
                .pmAppearFade()
            case .grid:
                catalogSongGrid(rowCount: rowCount)
                    .frame(
                        width: max(0, viewportWidth - PMSpace.xxxl * 2),
                        alignment: .leading
                    )
                    .padding(.horizontal, PMSpace.xxxl)
                    .pmAppearFade()
            }
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
    }

    private func macCatalogWindowedSongResults(
        rowCount: Int,
        range: Range<Int>,
        viewportWidth: CGFloat,
        ordinalWidth: CGFloat
    ) -> some View {
        let rowHeight = macVirtualRowHeight
        let rowWidth = max(0, viewportWidth - PMSpace.xxxl * 2)
        let visibleRange = range.clamped(to: 0..<max(0, rowCount))
        let columns = activeTableColumns
        let columnWidths = Dictionary(uniqueKeysWithValues: columns.map { ($0, columnWidth($0)) })
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: CGFloat(visibleRange.lowerBound) * rowHeight)
                .frame(minWidth: viewportWidth, alignment: .leading)
                .accessibilityHidden(true)

            ForEach(visibleRange, id: \.self) { position in
                Group {
                    if let song = catalogList.song(at: position) {
                        Group {
                            switch macViewMode {
                            case .list:
                                songTableRow(song, index: position, ordinalWidth: ordinalWidth, columns: columns, columnWidths: columnWidths)
                            case .compact:
                                compactSongRow(song, index: position, ordinalWidth: ordinalWidth)
                            case .grid:
                                EmptyView()
                            }
                        }
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            orderedIDs: { selectableOrderedSongIDs },
                            defaultAction: { playSong(song) }
                        )
                    } else {
                        Color.clear
                    }
                }
                .id(position)
                .frame(minWidth: rowWidth, alignment: .leading)
                .frame(height: rowHeight)
                .padding(.horizontal, PMSpace.xxxl)
            }

            Color.clear
                .frame(height: CGFloat(max(0, rowCount - visibleRange.upperBound)) * rowHeight)
                .frame(minWidth: viewportWidth, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(minWidth: viewportWidth, alignment: .leading)
    }

    private func catalogSongGrid(rowCount: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 6),
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(0..<rowCount, id: \.self) { position in
                Group {
                    if let song = catalogList.song(at: position) {
                        songGridTile(
                            song,
                            ordinal: position + 1,
                            isCurrent: player.currentSong?.id == song.id,
                            isLocated: locatedSongID == song.id
                        )
                        .songLocationRow(song.id, assignsScrollID: false)
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            style: .overlay,
                            orderedIDs: { selectableOrderedSongIDs },
                            defaultAction: { playSong(song) }
                        )
                    } else {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
                .id(position)
            }
        }
        .scrollTargetLayout()
        .padding(.top, 12)
    }

    private var macVirtualRowHeight: CGFloat {
        switch macViewMode {
        case .list:
            return 28 + macRowDensity.verticalPadding * 2
        case .compact:
            return 24
        case .grid:
            return 1
        }
    }

    /// 大封面标题区、来源筛选与工具栏固定在列表上方, 不随歌曲滚动: 切换来源 /
    /// 视图 / 排序时不必先滚回顶部, 滚动面里只剩表头与行, 窗口化的行区间也更小。
    /// 目录浏览没有来源筛选 (目录树自带根来源), 只保留工具栏。
    private var macPinnedSongListChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            macSongListHeader

            VStack(alignment: .leading, spacing: PMSpace.l) {
                if !showsFolderBrowser, case .library = scope {
                    sourceFilterChips
                }
                macToolbarRow
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.top, PMSpace.m14)
            .padding(.bottom, PMSpace.l)
        }
    }

    /// 滚动面自己的顶部: 列表视图是可置顶的表头, 紧凑视图留一点呼吸空间,
    /// 网格视图没有表头。空状态也放在这里, 没有行时它就是唯一内容。
    private func macSongScrollChrome(isEmpty: Bool, ordinalWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch macViewMode {
            case .list:
                if tableLayout.showsHeader {
                    VStack(alignment: .leading, spacing: 0) {
                        tableHeader(ordinalWidth: ordinalWidth)
                            .padding(.horizontal, MacSongTableLayout.horizontalPadding)
                            .padding(.vertical, 8)
                        Rectangle().fill(PMColor.divider).frame(height: 0.5)
                    }
                } else {
                    Color.clear.frame(height: 8)
                }
            case .compact:
                Color.clear.frame(height: 8)
            case .grid:
                EmptyView()
            }

            if isEmpty {
                macSongListEmptyState
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
        // 置顶后行会从它下面滚过, 必须是不透明底。
        .background(PMColor.bg)
    }

    @ViewBuilder
    private var macSongListEmptyState: some View {
        if isLocalOnlySongFilter {
            ContentUnavailableView(
                LocalizedStringKey(effectiveSongFilter == .offlineAvailable ? "filter_offline_available" : "filter_downloaded"),
                systemImage: effectiveSongFilter == .offlineAvailable ? "wifi.slash" : "arrow.down.circle",
                description: Text(
                    LocalizedStringKey(
                        effectiveSongFilter == .offlineAvailable
                            ? "filter_offline_available_empty_desc"
                            : "filter_downloaded_empty_desc"
                    )
                )
            )
            .padding(.top, 48)
        } else {
            ContentUnavailableView.search(text: searchText)
                .padding(.top, 48)
        }
    }

    private var macFolderSongList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: PMSpace.l) {
                if macFolderPath.isEmpty {
                    LibraryFolderRootContent(
                        folderCache: folderCache,
                        listCache: listCache,
                        rootSourceID: folderRootSourceID,
                        selection: selection,
                        sortOrder: $sortOrder,
                        onOpenFolder: openMacFolder
                    )
                } else {
                    MacLibraryFolderInlineContent(
                        folderPath: macFolderPath,
                        folderCache: folderCache,
                        listCache: listCache,
                        selection: selection,
                        sortOrder: $sortOrder,
                        onOpenFolder: openMacFolder,
                        onNavigate: navigateMacFolder
                    )
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 112)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .songLocationReader(songLocation, revision: FolderSongLocationRevision(
            nodeID: macFolderPath.last,
            indexRevision: folderCache.revision,
            songOrderRevision: listCache.rowOrderRevision
        ))
    }

    private var macSongListHeader: some View {
        let sourceTitle: String? = if case .source(let id) = scope {
            sourcesStore.source(id: id)?.name
        } else {
            nil
        }
        return MacLibraryHeader(
            eyebrow: sourceTitle == nil ? "library_title" : "sources_title",
            title: sourceTitle ?? String(localized: "tab_songs"),
            subtitle: librarySubtitle,
            iconSystemName: "music.note",
            coverSong: showsCatalogList
                ? catalogList.coverSong
                : listCache.coverSongID.flatMap { library.unobservedVisibleSong(id: $0) },
            canPlay: displayedPlayableCount > 0,
            onPlay: { playLibrary(shuffled: false) },
            onShuffle: { playLibrary(shuffled: true) },
            makeMoreMenu: { listMoreMenu }
        )
    }

    private var sourceFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: String(localized: "search_chip_all"),
                           count: showsCatalogList ? (catalogList.baseCount ?? 0) : listCache.songCount, color: nil,
                           active: selectedSourceID == nil && effectiveSongFilter == .all) {
                    selectedSourceID = nil
                    songFilter = .all
                }

                ForEach(sourcesStore.allSources.prefix(5), id: \.id) { source in
                    let count = showsCatalogList
                        ? catalogList.songCount(forSourceID: source.id)
                        : listCache.songCount(forSourceID: source.id)
                    if count > 0 {
                        sourceChip(title: source.name, count: count,
                                   color: sourceColor(source),
                                   active: selectedSourceID == source.id && effectiveSongFilter == .all) {
                            // 再点一次已选中的源 = 取消过滤回到全部。
                            songFilter = .all
                            selectedSourceID = (selectedSourceID == source.id) ? nil : source.id
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .pmStopsAtVerticalBar()
    }

    private func sourceChip(title: String, count: Int?, color: Color?, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                if let count {
                    Text(verbatim: count.formatted())
                        .monospacedDigit()
                        .opacity(0.65)
                }
            }
            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? .white : PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(active ? PMColor.brand : PMColor.glassBtn, in: Capsule())
            .overlay {
                Capsule().strokeBorder(active ? .clear : PMColor.cardBorder, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sourceColor(_ source: MusicSource) -> Color {
        switch source.type {
        case .baiduPan: return PMColor.brand
        case .appleMusic, .appleMusicLibrary: return Color(red: 0.64, green: 0.48, blue: 0.96)
        case .synology, .qnap, .ugreen, .fnos: return Color(red: 0.31, green: 0.68, blue: 0.95)
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return Color(red: 0.45, green: 0.82, blue: 0.56)
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic, .zspace, .fnMusic, .daoliyu, .songloft,
             .audiobookshelf, .synologyAudioStation, .tingReader:
            return Color(red: 0.98, green: 0.66, blue: 0.28)
        case .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123,
             .guangya, .pcloud, .infiniCloud: return Color(red: 0.42, green: 0.68, blue: 0.96)
        case .local: return PMColor.textFaint
        }
    }

    private var hasActiveMacFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || effectiveSongFilter != .all
            || selectedSourceID != nil
    }

    private var macDisplayedRowCount: Int {
        showsCatalogList ? catalogList.count : filteredRows.count
    }

    private var macToolbarRow: some View {
        HStack(spacing: 8) {
            locateCurrentButton
            MacLibraryFindField(
                text: $searchText,
                prompt: "filter_songs_placeholder",
                width: 220,
                accessibilityIdentifier: "songList.filter"
            )

            if !showsFolderBrowser && hasActiveMacFilter {
                Text(verbatim: LibraryCountText.results(macDisplayedRowCount))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .accessibilityIdentifier("songList.filterCount")
            }

            Spacer()

            SongListSortProgressIndicator(progress: sortProgress)

            Button {
                selectedSourceID = nil
                songFilter = songFilter == .offlineAvailable ? .all : .offlineAvailable
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: SongFilter.offlineAvailable.icon)
                        .imageScale(.small)
                    Text("filter_offline_available")
                }
                .macControlChrome(effectiveSongFilter == .offlineAvailable ? .selected : .glass)
            }
            .buttonStyle(.plain)
            .disabled(selection.isActive || sourceManager.isGlobalOfflineMode)
            .accessibilityAddTraits(effectiveSongFilter == .offlineAvailable ? .isSelected : [])
            .accessibilityIdentifier("songFilter.offlineAvailable")

            Button {
                selectedSourceID = nil
                songFilter = songFilter == .downloaded ? .all : .downloaded
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: SongFilter.downloaded.icon)
                        .imageScale(.small)
                    Text("filter_downloaded")
                }
                .macControlChrome(songFilter == .downloaded ? .selected : .glass)
            }
            .buttonStyle(.plain)
            .disabled(selection.isActive)
            .accessibilityAddTraits(songFilter == .downloaded ? .isSelected : [])
            .accessibilityIdentifier("songFilter.downloaded")

            browseModeSegment

            // 排序键上就写着当前怎么排(和歌单、专辑页一样), 前面不再单摆一个「排序方式」。
            Menu {
                SongSortMenuOptions(
                    sortOrder: $sortOrder,
                    followsListSort: showsFolderBrowser ? $folderFollowsListSort : nil
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .imageScale(.small)
                    if showsFolderBrowser, !folderFollowsListSort {
                        Text("sort_track_order")
                    } else {
                        Text(verbatim: sortOrder.label)
                        Image(systemName: sortOrder.directionIcon)
                            .font(.system(size: 9, weight: .bold))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .opacity(0.7)
                }
                .macControlChrome()
            }
            .macControlMenuStyle()
            .disabled(selection.isActive)
            .help(Text("sort_by"))
            .accessibilityLabel(Text("sort_by"))

            if !showsFolderBrowser {
                viewModeSegment

                // 行高 / 显示列只作用于列表视图; 显示方式已由左侧分段控件切换,
                // 弹框不再重复它, 其他视图下也就没有可调项, 直接不显示按钮。
                if macViewMode == .list {
                    MacControlIconButton(systemImage: "slider.horizontal.3", help: "songs_view_options") {
                        showViewOptions.toggle()
                    }
                    .popover(isPresented: $showViewOptions, arrowEdge: .bottom) {
                        viewOptionsPopover
                    }
                }
            }
        }
        // 大封面头部下面、表格正上方的工具条: 一律 26 高(`MacControlTier.toolbar`),
        // 原来定位键是系统按钮、视图选项是圆键, 和旁边的方角键混在一起。
        .macControlTier(.toolbar)
        .padding(.top, -4)
    }

    private var browseModeSegment: some View {
        // 目录被「已下载」或查找挡住时眼前是平铺：亮「平铺」，「目录」画灰但可点，点了说明原因。
        let displayedMode: LibrarySongBrowseMode = showsFolderBrowser ? .folder : .flat
        return HStack(spacing: 2) {
            ForEach(LibrarySongBrowseMode.allCases, id: \.self) { mode in
                let blocker = mode == .folder ? folderBrowseBlocker : nil
                Button {
                    if let blocker {
                        explainedFolderBlocker = blocker
                        explainsFolderBlocker = true
                    } else if mode != displayedMode {
                        browseMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .folder ? "folder" : "list.bullet")
                            .imageScale(.small)
                        Text(mode == .folder ? "library_browse_folder" : "library_browse_flat")
                    }
                    .opacity(blocker == nil ? 1 : 0.45)
                    .macSegment(selected: displayedMode == mode)
                }
                .buttonStyle(.plain)
                .disabled(selection.isActive)
                .accessibilityAddTraits(displayedMode == mode ? .isSelected : [])
                .accessibilityHint(blocker.map { Text($0.titleKey) } ?? Text(verbatim: ""))
                .accessibilityIdentifier("libraryBrowseMode.\(mode.rawValue)")
            }
        }
        .macSegmentedContainer()
        .accessibilityElement(children: .contain)
        .folderBrowseBlockerAlert(
            isPresented: $explainsFolderBlocker,
            blocker: explainedFolderBlocker,
            resolve: resolveFolderBrowseBlocker
        )
    }

    private var viewModeSegment: some View {
        HStack(spacing: 2) {
            ForEach(MacSongsViewMode.allCases, id: \.self) { mode in
                Button {
                    macViewMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .macSegment(selected: macViewMode == mode, iconOnly: true)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: mode.title))
                .accessibilityLabel(Text(verbatim: mode.title))
                .accessibilityAddTraits(macViewMode == mode ? .isSelected : [])
            }
        }
        .macSegmentedContainer()
    }

    private var librarySubtitle: String {
        let total = showsCatalogList ? (catalogList.baseCount ?? 0) : listCache.songCount
        let playable = showsCatalogList ? catalogList.basePlayableCount : listCache.playableCount
        let duration = showsCatalogList ? catalogList.baseTotalDuration : listCache.totalDuration
        return "\(LibraryCountText.songs(total)) · \(LibraryCountText.playableRatio(playable: playable, total: total)) · \(duration.formattedShort)"
    }

    private var activeTableColumns: [MacSongsColumn] { tableLayout.activeColumns }

    private func columnWidth(_ column: MacSongsColumn) -> CGFloat { tableLayout.width(column) }

    private func tableContentWidth(ordinalWidth: CGFloat) -> CGFloat {
        tableLayout.contentWidth(ordinalWidth: ordinalWidth)
    }

    private func tableHeader(ordinalWidth: CGFloat) -> some View {
        MacSongTableHeader(layout: tableLayout, ordinalWidth: ordinalWidth, sortOrder: sortOrder.libraryOrder) { criterion in
            if showsFolderBrowser { folderFollowsListSort = true }
            sortOrder = sortOrder.selecting(criterion)
        }
    }

    /// 一次性把 PlayHistory 折叠成 songID → count 字典, 避免每行 O(N) 扫描。
    /// 结果写入 @State playCountsBySongID, 仅在 onAppear / 变更通知时调用。
    /// 折叠放到后台: 播放记录上万条时在主线程上折, 正赶上换页那一帧, 进页面就慢半拍。
    private func rebuildPlayCounts() {
        let entries = PlayHistoryStore.shared.entries
        playCountsTask?.cancel()
        playCountsTask = Task { @MainActor in
            let dict = await Task.detached(priority: .utility) {
                var dict: [String: Int] = [:]
                for entry in entries {
                    dict[entry.songID, default: 0] += 1
                }
                return dict
            }.value
            guard !Task.isCancelled else { return }
            applyPlayCounts(dict)
        }
    }

    private func applyPlayCounts(_ dict: [String: Int]) {
        guard dict != playCountsBySongID else { return }
        playCountsBySongID = dict
        sortValuesVersion.invalidate(.playCount)
        if sortOrder.criterion == .playCount {
            scheduleSortedRecompute(
                delay: .milliseconds(40),
                pruneRowModels: false,
                isExplicitSort: activeSortIsExplicit
            )
        }
    }

    private func songTableRow(
        _ song: Song,
        index: Int,
        ordinalWidth: CGFloat,
        columns: [MacSongsColumn],
        columnWidths: [MacSongsColumn: CGFloat]
    ) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let isLocated = locatedSongID == song.id
        let source = columns.contains(.source)
            ? sourcesStore.sources.first(where: { $0.id == song.sourceID })
            : nil
        return MacSongRowContainer(
            content: MacSongTableRowContent(
                showsRowNumbers: showsRowNumbers,
                song: song,
                ordinal: index + 1,
                ordinalWidth: ordinalWidth,
                isCurrent: isCurrent,
                isEmphasized: isCurrent || isLocated,
                liked: playlistContains(song),
                plays: playCountsBySongID[song.id] ?? 0,
                artistName: columns.contains(.artist) ? library.artistDisplayName(for: song) : nil,
                isDownloaded: downloadedSongIDs.contains(song.id),
                sourceName: source.map {
                    $0.name.components(separatedBy: "·").first?
                        .trimmingCharacters(in: .whitespaces) ?? $0.name
                },
                sourceDotColor: source.map { macSourceDotColor(for: $0) },
                columns: columns,
                columnWidths: columnWidths,
                contentWidth: tableContentWidth(ordinalWidth: ordinalWidth),
                verticalPadding: macRowDensity.verticalPadding,
                locale: locale
            ),
            play: { playSong(song) },
            menu: { macSongContextMenu(for: song) }
        )
        .equatable()
        .songLocationRow(song.id, assignsScrollID: false)
    }

    private func compactSongRow(_ song: Song, index: Int, ordinalWidth: CGFloat) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let isLocated = locatedSongID == song.id
        return MacSongRowContainer(
            content: MacCompactSongRowContent(
                showsRowNumbers: showsRowNumbers,
                song: song,
                ordinal: index + 1,
                ordinalWidth: ordinalWidth,
                isCurrent: isCurrent,
                isEmphasized: isCurrent || isLocated,
                liked: playlistContains(song),
                artistName: library.artistDisplayName(for: song),
                locale: locale
            ),
            play: { playSong(song) },
            menu: { macSongContextMenu(for: song) }
        )
        .equatable()
        .songLocationRow(song.id, assignsScrollID: false)
    }

    private func songGrid(rows: [SongListRowIdentity]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 6),
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(rows.indices, id: \.self) { position in
                let row = rows[position]
                Group {
                    if let song = library.unobservedVisibleSong(id: row.id) {
                        songGridTile(
                            song,
                            ordinal: row.offset + 1,
                            isCurrent: player.currentSong?.id == song.id,
                            isLocated: locatedSongID == song.id
                        )
                        .songLocationRow(song.id, assignsScrollID: false)
                        .songSelectable(
                            songID: row.id,
                            selection: selection,
                            style: .overlay,
                            orderedIDs: { filteredSongIDs },
                            defaultAction: { playSong(song) }
                        )
                    } else {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
                .id(position)
            }
        }
        .scrollTargetLayout()
        .padding(.top, 12)
    }

    private func songGridTile(_ song: Song, ordinal: Int, isCurrent: Bool, isLocated: Bool) -> some View {
        let isEmphasized = isCurrent || isLocated
        return PMScrollingButton { playSong(song) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        cornerRadius: 8,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .aspectRatio(1, contentMode: .fit)

                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(PMColor.brand, in: .circle)
                            .shadow(color: .black.opacity(0.30), radius: 8, y: 2)
                            .padding(8)
                    }
                }

                SongRowNumberedTitle(number: ordinal, title: song.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEmphasized ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 8)

                Text(library.artistDisplayName(for: song) ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .background {
            if isLocated {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PMColor.brand.opacity(0.12))
                    .padding(-6)
            }
        }
        // 网格 tile 过去没有任何悬停反馈；hover 状态记在修饰符里，不会让 tile 重算。
        .pmHoverLift()
        .contextMenu { macSongContextMenu(for: song) }
    }

    @ViewBuilder
    private func macSongContextMenu(for song: Song) -> some View {
        Section {
            Button {
                playSong(song)
            } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!song.isPlayable)

            Button {
                player.insertNextInQueue([song])
            } label: {
                Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!song.isPlayable)

            Button {
                player.appendToQueue([song])
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!song.isPlayable)
        }

        Section {
            Button {
                showSongInfo(for: song)
            } label: {
                Label(String(localized: "song_info"), systemImage: "info.circle")
                    .labelStyle(.titleAndIcon)
            }

            SongCopyTitleButton(song: latestSong(song))

            // 刮削数据、编辑标签、编辑歌词、重新读取文件标签：顺序、文案、可用条件和 iPhone 长按菜单「编辑」里一样。
            Button {
                openScrapeWindow(for: song)
            } label: {
                Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            }

            Button {
                editTags(for: song)
            } label: {
                Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                    .labelStyle(.titleAndIcon)
            }

            Button {
                contextSongAction = SongRowActionRequest(song: latestSong(song), action: .editLyrics)
            } label: {
                Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                    .labelStyle(.titleAndIcon)
            }

            Button {
                addToPlaylist(song)
            } label: {
                Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                    .labelStyle(.titleAndIcon)
            }

            macSpokenWordClassificationButton(for: song)

            MacRereadSongTagsMenuButton(song: song) {
                contextSongAction = SongRowActionRequest(song: latestSong(song), action: .rereadTags)
            }

            SongPlaybackRangeMenuItems(song: latestSong(song)) { purpose in
                contextPlaybackRangeRequest = .init(song: latestSong(song), purpose: purpose)
            }

            SongShuffleLinkMenu(songID: song.id)
        }

        if song.sourceID != AppleMusicLibraryService.systemSourceID {
            Section {
                SongOfflineActionButtons(
                    song: song,
                    snapshot: sourceManager.offlineAudioSnapshotEntry(for: song).snapshot
                )
                .task(id: song.id) {
                    await sourceManager.ensureOfflineAudioSnapshot(for: song)
                }
            }
        }

        Section {
            SongFeedbackMenuButtons(songID: song.id)

            Button {
                contextShareSong = latestSong(song)
            } label: {
                Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// iPhone 的歌曲菜单里早就有这一项; Mac 的本地文件夹没有可以标成有声的目录页,
    /// 没有它就只能靠播放时的提示一首一首地搬。
    @ViewBuilder
    private func macSpokenWordClassificationButton(for song: Song) -> some View {
        ListeningKindMoveButtons(current: SpokenWordStore.shared.kind(for: song)) { kind in
            SpokenWordStore.shared.move([latestSong(song)], to: kind)
            library.refreshContentClassification()
        }
    }

    private func latestSong(_ song: Song) -> Song {
        library.song(id: song.id) ?? song
    }

    private func showSongInfo(for song: Song) {
        contextSongInfoSong = latestSong(song)
    }

    private func editTags(for song: Song) {
        contextTagEditorSong = latestSong(song)
    }

    private func addToPlaylist(_ song: Song) {
        contextAddToPlaylistSong = latestSong(song)
    }

    private func openScrapeWindow(for song: Song) {
        let song = latestSong(song)
        scraperSettings.performSingleSongScrapeAction(
            from: .macSongListContextMenu,
            onProceed: {
                ScrapeWindowController.shared.show(song: song) { updated in
                    CachedArtworkView.invalidateCache(for: updated.id)
                    if let oldRef = song.coverArtFileName {
                        CachedArtworkView.invalidateCache(for: oldRef)
                    }
                    player.syncSongMetadata(updated)
                    if player.currentSong?.id == updated.id { player.forceRefreshNowPlayingArtwork() }
                }
            },
            onRequireSource: {
                showNoScraperSourceAlert = true
            }
        )
    }

    private var listMoreMenu: AnyView {
        // Header/menu construction is part of every macOS body update. Keep it
        // on lightweight IDs; materialize 10K Song values only after the user
        // actually invokes an action.
        let usesCatalogRows = showsCatalogList
        let projection = usesCatalogRows ? SongListProjection.empty : filteredProjection
        let visibleIDs = projection.orderedSongIDs
        let visibleCount = usesCatalogRows ? catalogList.count : visibleIDs.count
        let playableCount = usesCatalogRows ? catalogList.listPlayableCount : projection.playableCount
        let library = self.library

        func resolve(_ ids: [String], playableOnly: Bool) -> [Song] {
            ids.compactMap { songID in
                guard let song = library.unobservedVisibleSong(id: songID),
                      !playableOnly || song.isPlayable else { return nil }
                return song
            }
        }

        /// 内存路径直接用手里的 id;目录路径按显示顺序取好 id 再做。歌按 id 从内存模型取
        /// (加入队列、导出、刮削的接口只收 `[Song]`)。
        func withVisibleSongs(playableOnly: Bool, _ body: @escaping @MainActor ([Song]) -> Void) {
            if usesCatalogRows {
                withCatalogSongIDs { ids in body(resolve(ids, playableOnly: playableOnly)) }
            } else {
                body(resolve(visibleIDs, playableOnly: playableOnly))
            }
        }

        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "checkmark.circle",
                      title: selection.isActive
                          ? String(localized: "done")
                          : String(localized: "batch_select"),
                      enabled: visibleCount > 0) {
                    if selection.isActive {
                        selection.deactivate()
                    } else {
                        selection.activate()
                    }
                },
            ],
            [
                .init(icon: "text.line.last.and.arrowtriangle.forward",
                      title: String(localized: "queue_all_songs"),
                      trailing: playableCount.formatted(),
                      enabled: playableCount > 0) {
                    withVisibleSongs(playableOnly: true) { player.appendToQueue($0) }
                },
                .init(icon: "text.line.first.and.arrowtriangle.forward",
                      title: String(localized: "insert_next"),
                      enabled: playableCount > 0) {
                    withVisibleSongs(playableOnly: true) { player.insertNextInQueue($0) }
                },
                .init(icon: "text.badge.plus",
                      title: String(localized: "add_to_playlist_ellipsis"),
                      enabled: playableCount > 0) {
                    if usesCatalogRows {
                        withVisibleSongs(playableOnly: true) { songs in
                            catalogBatchSongs = songs
                            showAddVisibleToPlaylist = true
                        }
                    } else {
                        showAddVisibleToPlaylist = true
                    }
                },
            ],
            [
                .init(icon: "shuffle",
                      title: String(localized: "shuffle_all"),
                      enabled: playableCount > 0) {
                    playLibrary(shuffled: true)
                },
            ],
            [
                .init(icon: "wand.and.stars",
                      title: String(localized: "scrape_missing_metadata"),
                      trailing: visibleCount.formatted(),
                      enabled: visibleCount > 0 && !scraperService.isScraping) {
                    guard scraperSettings.hasEnabledSource else {
                        showNoScraperSourceAlert = true
                        return
                    }
                    withVisibleSongs(playableOnly: false) { songs in
                        scraperService.scrapeMissingMetadata(songs: songs, in: library)
                    }
                },
                .init(icon: "square.and.arrow.up",
                      title: String(localized: "export_m3u8_ellipsis"),
                      enabled: playableCount > 0) {
                    withVisibleSongs(playableOnly: true) { exportSongs($0, format: .m3u8) }
                },
                .init(icon: "curlybraces",
                      title: String(localized: "export_json_ellipsis"),
                      enabled: playableCount > 0) {
                    withVisibleSongs(playableOnly: true) { exportSongs($0, format: .json) }
                },
            ],
            [
                .init(icon: "list.bullet.rectangle",
                      title: String(localized: "songs_column_settings_ellipsis"),
                      enabled: macViewMode == .list) {
                    showViewOptions = true
                },
            ],
        ]))
    }

    private var viewOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("songs_view_options")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)

            viewOptionsSection(String(localized: "songs_row_height")) {
                segmentedIconPicker(MacSongsRowDensity.allCases, selection: $macRowDensity)
            }

            MacSongTableColumnOptions(layout: tableLayout)
        }
        .padding(16)
        .frame(width: 280)
        // 系统 popover 的半透材质叠在内容后面会让白色选中块显得过亮 / 发灰;
        // 铺一层 flat 不透明底 (不画圆角边框, 系统 chrome 会裁圆角, 不会双框),
        // 选中块就跟工具栏里的视图切换一样是"米色上一块白"的柔和效果。
        .background(PMColor.bg)
    }

    private func viewOptionsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            content()
        }
    }

    private func segmentedIconPicker<T: CaseIterable & Hashable>(_ values: T.AllCases, selection: Binding<T>) -> some View where T.AllCases: RandomAccessCollection {
        HStack(spacing: 2) {
            ForEach(Array(values), id: \.self) { value in
                let item = segmentInfo(for: value)
                Button {
                    selection.wrappedValue = value
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(verbatim: item.title)
                            .font(.system(size: 9, weight: selection.wrappedValue == value ? .semibold : .medium))
                    }
                    .foregroundStyle(selection.wrappedValue == value ? PMColor.brand : PMColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(selection.wrappedValue == value ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 6))
                    .shadow(color: selection.wrappedValue == value ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                    // 整段都可点选, 而不是只点中图标/文字才生效。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
    }

    private func segmentInfo<T>(for value: T) -> (title: String, icon: String) {
        if let mode = value as? MacSongsViewMode { return (mode.title, mode.icon) }
        if let density = value as? MacSongsRowDensity { return (density.title, density.icon) }
        return ("", "circle")
    }

    private func exportSongs(_ songs: [Song], format: PlaylistExporter.Format) {
        do {
            let playlist = Playlist(name: String(localized: "tab_songs"))
            let url = try PlaylistExporter.export(
                playlist: playlist,
                songs: songs,
                format: format,
                sourcesStore: sourcesStore
            )
            try PlaylistExporter.presentSavePanel(for: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func macSourceDotColor(for source: MusicSource) -> Color {
        let palette: [Color] = [
            PMColor.flac, PMColor.dsd, PMColor.warn, PMColor.brand,
            Color(red: 0.4, green: 0.7, blue: 0.95),
            Color(red: 0.7, green: 0.6, blue: 0.95),
        ]
        let h = source.type.rawValue.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[h]
    }

    private func playlistContains(_ song: Song) -> Bool {
        library.isLiked(songID: song.id)
    }

    private func playLibrary(shuffled: Bool) {
        if showsCatalogList {
            withCatalogSongIDs { ids in
                player.shuffleEnabled = shuffled
                Task { await player.play(queueIDs: ids, order: shuffled ? .shuffled : .asGiven) }
            }
            return
        }
        let ids = filteredSongIDs
        guard !ids.isEmpty else { return }
        player.shuffleEnabled = shuffled
        Task { await player.play(queueIDs: ids, order: shuffled ? .shuffled : .asGiven) }
    }
    #endif

    private var locateCurrentButton: LocateCurrentSongButton {
        LocateCurrentSongButton(
            isEditing: selection.isActive,
            titled: verticalBarEdge != nil,
            contains: { id in
                // 目录列表就是这一页的整个范围。
                if showsCatalogList { return pageScopeContains(id) }
                if !listCache.isEmpty { return listCache.contains(songID: id) }
                if showsFolderBrowser, let index = folderCache.index {
                    return index.nodeID(containingSongID: id) != nil
                }
                // 列表还在排序、目录还在分（刚推入这一页）：先按这一页的范围认，工具栏一开始就是排好后的那几颗键。
                return pageScopeContains(id)
            },
            isVisible: { id in
                if showsCatalogList { return catalogListShows(id) }
                return showsFolderBrowser
                    // 还没排好时没有筛选就算在列表里：定位请求留着，列表出来再滚过去。
                    || (listCache.isEmpty && folderBrowseBlocker == nil)
                    || filteredProjection.rows.contains { $0.id == id }
            }
        ) { songID, clearsFilters in
            if clearsFilters {
                searchText = ""
                #if os(iOS)
                appliedSearchText = ""
                #endif
                songFilter = .all
                #if os(macOS)
                selectedSourceID = nil
                #endif
            }
            locateSong(songID)
        }
    }

    /// 列表排好以前，定位也按当前页面的来源和内容范围判断。
    private func pageScopeContains(_ songID: String) -> Bool {
        guard scope.showsAudiobookshelfContents(in: sourcesStore) || !library.nonMusicSongIDs.contains(songID),
              let song = library.unobservedVisibleSong(id: songID) else { return false }
        switch scope {
        case .library: return true
        case .source(let sourceID): return song.sourceID == sourceID
        }
    }

    private func locateSong(_ songID: String) {
        if showsFolderBrowser {
            pendingFolderLocation = SongLibraryLocationRequest(songID: songID)
            resolvePendingFolderLocation()
        } else {
            songLocation.locate(songID)
        }
    }

    private func resolvePendingFolderLocation() {
        guard let request = pendingFolderLocation,
              let nodeID = folderCache.index?.nodeID(containingSongID: request.songID) else { return }
        pendingFolderLocation = nil
        #if os(iOS)
        folderLocationDestination = FolderSongLocationRequest(nodeID: nodeID, song: request)
        #else
        openMacFolder(nodeID)
        songLocation.locate(request.songID)
        #endif
    }

    #if os(iOS)
    private var moreMenuItems: SongListMoreMenuItems {
        SongListMoreMenuItems(
            selection: selection, sortOrder: $sortOrder, filter: $songFilter,
            manageHomeFolders: showsFolderBrowser ? { showsHomeFolders = true } : nil,
            folderFollowsListSort: showsFolderBrowser ? $folderFollowsListSort : nil
        )
    }

    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SongListToolbarPrincipal(selection: selection, progress: sortProgress)
        }
        if selection.isActive {
            SongSelectionToolbarItems(selection: selection, orderedIDs: { batchOrderedSongIDs }, titled: verticalBarEdge != nil)
        } else {
            let locate = locateCurrentButton
            let locateTarget = locate.targetID(player: player, library: library)
            let canShuffle = !showsFolderBrowser && displayedPlayableCount > 1
            PMCollapsibleToolbar(actionCount: sectionRailActive || locateTarget != nil ? 4 : 3) {
                locate
                SongListShuffleToolbarButton(
                    selection: selection,
                    isEnabled: canShuffle,
                    titled: verticalBarEdge != nil,
                    action: shuffleVisibleSongs
                )
                SongListBrowseModeToolbarButton(
                    selection: selection, browseMode: $browseMode, folderBlocker: folderBrowseBlocker,
                    explainBlocker: explainFolderBrowseBlocker, titled: verticalBarEdge != nil
                )
            } primary: { collapsesActions in
                moreMenu(collapsesActions: collapsesActions, locate: locate, locateTarget: locateTarget, canShuffle: canShuffle)
            }
        }
    }

    /// 工具栏里那颗「⋯」。收起与否都是这一颗系统菜单，推入的第一帧就画好、不改宽度：从一开始就在最后的位置上。
    /// 四颗键时顶栏只剩它，定位、随机、目录 / 平铺排在菜单顶上一行。
    private func moreMenu(
        collapsesActions: Bool, locate: LocateCurrentSongButton, locateTarget: String?, canShuffle: Bool
    ) -> some View {
        PMToolbarMoreMenu(
            collapsesShortcuts: collapsesActions,
            identifier: "songList.more",
            titled: verticalBarEdge != nil
        ) {
            locate.menuItem(target: locateTarget, filteredTarget: $filteredLocationTarget)
            SongListMenuQuickActions(
                canShuffle: canShuffle,
                shuffle: shuffleVisibleSongs,
                browseMode: $browseMode,
                folderBlocker: folderBrowseBlocker,
                explainBlocker: explainFolderBrowseBlocker
            )
        } items: {
            moreMenuItems
        }
    }
    #endif

    /// 过滤条件变了或歌被删了之后，丢掉已经不在列表里的选中项 —— 否则批量
    /// 操作会作用到用户此刻根本看不见的歌上。
    private func pruneSelection() {
        guard selection.isActive, !selection.isEmpty else { return }
        if showsCatalogList {
            // 目录列表的 id 还没取好时不修剪(取好后 `selectionIDsDidLoad` 再修剪)。
            guard let ids = catalogList.selectionIDs else { return }
            selection.prune(to: Set(ids))
            return
        }
        selection.prune(to: Set(batchOrderedSongIDs))
    }

    /// 目录列表里这首在不在眼前(Mac 选了来源筛选时只看那个源)。
    private func catalogListShows(_ songID: String) -> Bool {
        #if os(macOS)
        if let selectedSourceID {
            return library.unobservedVisibleSong(id: songID)?.sourceID == selectedSourceID
        }
        #endif
        return true
    }

    /// Normal browsing returns worker-built arrays by reference. A source/search
    /// projection is materialized once per snapshot/filter key and shared by
    /// every body consumer instead of repeating filter/reindex/map work.
    private var filteredProjection: SongListProjection {
        #if os(macOS)
        let sourceID = selectedSourceID
        #else
        let sourceID: String? = nil
        #endif
        let includedSongIDs = isLocalOnlySongFilter ? downloadedSongIDs : nil
        return listCache.projection(
            sourceID: sourceID,
            query: projectionQuery,
            includedSongIDs: includedSongIDs,
            filterRevision: downloadedFilterRevision,
            replacementToken: songListVersion.replacementToken,
            resolve: { library.unobservedVisibleSong(id: $0) }
        )
    }

    private func scheduleDownloadedFilterRefresh(delay: Duration? = nil) {
        downloadedFilterGeneration &+= 1
        let generation = downloadedFilterGeneration
        let songsSnapshot = songs
        let filterMode = effectiveSongFilter
        let localSourceIDs = localDeviceSourceIDs
        downloadedFilterTask?.cancel()
        isDownloadedFilterLoading = true

        downloadedFilterTask = Task { @MainActor in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            let resolvedIDs: Set<String>
            if filterMode == .offlineAvailable {
                resolvedIDs = await sourceManager.offlinePlayableSongIDs(
                    in: songsSnapshot,
                    localSourceIDs: localSourceIDs
                )
            } else {
                resolvedIDs = await sourceManager.downloadedSongIDs(in: songsSnapshot)
            }
            guard !Task.isCancelled,
                  downloadedFilterGeneration == generation else { return }
            let changed = downloadedSongIDs != resolvedIDs
            if changed {
                downloadedSongIDs = resolvedIDs
                downloadedFilterRevision &+= 1
                sortValuesVersion.invalidate(.downloaded)
            }
            isDownloadedFilterLoading = false
            downloadedFilterTask = nil
            if isLocalOnlySongFilter {
                pruneSelection()
            }
            if changed, sortOrder.criterion == .downloaded {
                scheduleSortedRecompute(
                    delay: .milliseconds(40),
                    pruneRowModels: false,
                    isExplicitSort: activeSortIsExplicit
                )
            }
        }
    }

    private var filteredRows: [SongListRowIdentity] {
        filteredProjection.rows
    }

    private var projectionQuery: String {
        #if os(iOS)
        appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }

    private var filteredSongIDs: [String] {
        filteredProjection.orderedSongIDs
    }

    private var batchOrderedSongIDs: [String] {
        #if os(macOS)
        if showsFolderBrowser, let nodeID = macFolderPath.last {
            return folderCache.orderedSongIDs(
                in: nodeID,
                scope: .action,
                listCache: listCache
            )
        }
        #endif
        if showsCatalogList {
            // 多选开始时按显示顺序取一次;还没取好时先只给已选的那些。
            return catalogList.selectionIDs ?? Array(selection.selectedIDs)
        }
        return showsFolderBrowser
            ? (listCache.isEmpty ? songs.map(\.id) : listCache.orderedSongIDs)
            : filteredSongIDs
    }

    private var requiresSortedSnapshot: Bool {
        // 目录列表不需要内存里的整库快照。
        if usesCatalogList { return false }
        #if os(macOS)
        return true
        #else
        return !showsFolderBrowser || folderFollowsListSort
        #endif
    }

    private func ensureSortedSnapshotIfNeeded() {
        guard requiresSortedSnapshot, listCache.isEmpty else { return }
        if let cached = SongListSnapshotStore.shared.cachedSnapshot(
            scopeKey: scope.snapshotCacheKey,
            version: songListVersion,
            order: sortOrder.libraryOrder,
            sortValuesVersion: sortValuesVersion
        ) {
            sortGeneration &+= 1
            publishSnapshotWithoutAnimation(
                cached,
                pruneRowModels: false,
                isExplicitSort: false,
                generation: sortGeneration,
                order: sortOrder.libraryOrder
            )
        } else {
            scheduleSortedRecompute(pruneRowModels: false)
        }
    }

    private var batchActionContext: SongBatchActionContext {
        #if os(macOS)
        if showsFolderBrowser,
           macFolderPath.last?.sourceID == AppleMusicLibraryIdentity.sourceID {
            return .readOnly
        }
        #endif
        return .library
    }

    /// Materialize Song values only for explicit actions (queue, export,
    /// scrape), never as the List's structural data.
    private var filteredSongs: [Song] {
        filteredSongIDs.compactMap { library.unobservedVisibleSong(id: $0) }
    }

    /// Patch only the rows touched by a metadata replacement. Do not reorder
    /// the complete list while background scraping/backfill is publishing:
    /// besides forcing a 10K-row List diff, that could move the row whose
    /// More menu the user is currently operating. The next explicit sort,
    /// collection change, or appearance rebuilds the order from fresh data.
    private func applyLibrarySongReplacements() {
        let replacedIDs = replacedSongIDs
        guard !replacedIDs.isEmpty, !listCache.isEmpty else { return }

        var replacements: [String: Song] = [:]
        replacements.reserveCapacity(replacedIDs.count)
        for songID in replacedIDs {
            guard listCache.contains(songID: songID),
                  let latest = library.unobservedVisibleSong(id: songID),
                  belongsToCurrentScope(latest)
            else { continue }
            replacements[songID] = latest
        }

        guard !replacements.isEmpty else { return }
        listCache.patch(replacements, resolve: { library.unobservedVisibleSong(id: $0) })
    }

    /// A full scan can replace a Song in place while preserving the ordered
    /// song IDs, so `visibleSongCollectionRevision` intentionally does not
    /// change. Compare only the replaced IDs against the existing index and
    /// rebuild when source/path placement moved; title/artist/lyrics updates
    /// stay on the cheap row-patch path.
    private func folderReplacementChangesStructure() -> Bool {
        guard browseMode == .folder,
              let index = folderCache.index,
              !replacedSongIDs.isEmpty else {
            return false
        }

        var descriptorsByID: [String: LibraryFolderSourceDescriptor] = [:]
        for descriptor in configuredFolderSourceDescriptors
        where descriptorsByID[descriptor.sourceID] == nil {
            descriptorsByID[descriptor.sourceID] = descriptor
        }
        for songID in replacedSongIDs {
            let indexedNodeID = index.nodeID(containingSongID: songID)
            if let song = library.unobservedVisibleSong(id: songID) {
                if song.sourceID == AppleMusicLibraryIdentity.sourceID {
                    continue
                }
                // Provider item IDs stay stable across metadata replacement
                // and provider moves. Their folder placement is invalidated by
                // the committed sync-state revision instead of reinterpreting
                // the opaque playback ID here.
                if let sourceType = sourcesStore.allSources.first(where: {
                    $0.id == song.sourceID
                })?.type,
                   sourceType.isCloudDrive
                    || sourceType.isServerLibrary
                    || sourceType == .upnp {
                    continue
                }
            }
            let expectedNodeID: LibraryFolderNodeID?
            if let song = library.unobservedVisibleSong(id: songID),
               belongsToCurrentScope(song) {
                let descriptor: LibraryFolderSourceDescriptor
                if let configured = descriptorsByID[song.sourceID] {
                    descriptor = configured
                } else {
                    let fallback = fallbackFolderSourceDescriptor(for: song)
                    descriptorsByID[song.sourceID] = fallback
                    descriptor = fallback
                }
                expectedNodeID = descriptor.placementNodeID(for: song)
            } else {
                expectedNodeID = nil
            }

            if indexedNodeID != expectedNodeID {
                return true
            }
        }
        return false
    }

    private func belongsToCurrentScope(_ song: Song) -> Bool {
        switch scope {
        case .library:
            return library.containsVisibleSong(id: song.id)
        case .source(let sourceID):
            return song.sourceID == sourceID && library.containsVisibleSong(id: song.id)
        }
    }

    private func folderSourceDescriptors(
        for songsSnapshot: [Song],
        configured descriptors: [LibraryFolderSourceDescriptor]
    ) -> [LibraryFolderSourceDescriptor] {
        var result = descriptors
        var knownSourceIDs = Set(descriptors.map(\.sourceID))
        for song in songsSnapshot where knownSourceIDs.insert(song.sourceID).inserted {
            result.append(fallbackFolderSourceDescriptor(for: song))
        }
        return result
    }

    private func fallbackFolderSourceDescriptor(
        for song: Song
    ) -> LibraryFolderSourceDescriptor {
        // The system Apple Music mirror normally has a SourcesStore row, but
        // older snapshots and imported libraries may not. Unknown providers
        // are intentionally opaque and get a generic safe name; never expose
        // their ID or playback reference as a path label.
        let displayName = song.sourceID == AppleMusicLibraryIdentity.sourceID
            ? String(localized: "apple_music_library_section")
            : String(localized: "source_label")
        return LibraryFolderSourceDescriptor(
            sourceID: song.sourceID,
            displayName: displayName,
            scanRoots: [],
            pathSemantics: .opaque
        )
    }

    /// Build the immutable prefix index away from the main actor. Metadata-only
    /// replacements deliberately do not call this path: folder structure depends
    /// on collection membership, source configuration, sourceID, and filePath,
    /// not on title/artist/lyrics backfill publications.
    private func scheduleFolderIndexRecompute(delay: Duration? = nil) {
        guard browseMode == .folder else { return }

        folderIndexGeneration &+= 1
        let generation = folderIndexGeneration
        let songsSnapshot = songs
        let configuredDescriptors = configuredFolderSourceDescriptors
        var providerHierarchyInputs: [String: ProviderFolderHierarchyInput] = [:]
        for descriptor in configuredDescriptors {
            guard let sourceType = sourcesStore.allSources.first(where: {
                $0.id == descriptor.sourceID
            })?.type,
                  sourceType.isCloudDrive
                    || sourceType.isServerLibrary
                    || sourceType == .upnp else { continue }
            providerHierarchyInputs[descriptor.sourceID] = ProviderFolderHierarchyInput(
                syncIndex: scanService.libraryFolderSyncIndex(for: descriptor.sourceID),
                rootDisplayNames: sourceType.isCloudDrive
                    ? CloudDirectoryNameStore.displayNames(for: descriptor.sourceID)
                    : [:],
                usesIndexedRoots: sourceType.isServerLibrary || sourceType == .upnp
            )
        }
        let sourceRevision = folderSourceRevision
        let collectionRevision = songListVersion.collectionRevision
        let playlistRevision = library.playlistCollectionRevision
        let virtualCollections = library.appleMusicFolderCollections(
            availableSongs: songsSnapshot
        )
        let version = LibraryFolderIndexVersion(
            collectionRevision: collectionRevision,
            // This token identifies this view/store scope; metadata-only song
            // replacements must not invalidate a 100k-folder index on return.
            replacementToken: folderIndexScopeToken,
            sourceRevision: sourceRevision,
            virtualCollectionRevision: playlistRevision
        )
        let baseDescriptors = folderSourceDescriptors(
            for: songsSnapshot,
            configured: configuredDescriptors
        )
        // 照这一份输入建好的整库索引留给下一个歌曲页直接用(见 `publishReusableFolderIndex`)。
        let reuseKey = folderIndexReuseKey
        // 目录可读时按目录建:索引里每首歌只留行号,不再存整库的 id 与 id → 节点表。
        let catalogReader = library.readableCatalogReader
        let catalogVersion = LibraryFolderIndexVersion(
            collectionRevision: collectionRevision,
            replacementToken: folderIndexScopeToken,
            sourceRevision: sourceRevision,
            virtualCollectionRevision: playlistRevision,
            catalogRevision: library.folderIndexCatalogRevision
        )
        let catalogScope = folderCatalogScope
        let virtualSourceIDs = Set(virtualCollections.filter { $0.kind == .librarySongs }.map(\.sourceID))
        let appleMusicName = String(localized: "apple_music_library_section")
        let genericSourceName = String(localized: "source_label")

        folderIndexTask?.cancel()
        folderIndexTask = Task { @MainActor in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let descriptors = await Task.detached(priority: .userInitiated) {
                [baseDescriptors, providerHierarchyInputs] in
                baseDescriptors.map { descriptor in
                    guard let input = providerHierarchyInputs[descriptor.sourceID] else {
                        return descriptor
                    }
                    return descriptor.attachingProviderHierarchy(
                        syncIndex: input.syncIndex,
                        rootDisplayNames: input.rootDisplayNames,
                        usesIndexedRoots: input.usesIndexedRoots
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            var catalogPrepared: LibraryFolderIndex?
            if let catalogReader {
                catalogPrepared = await folderIndexStore.index(version: catalogVersion) {
                    [descriptors, songsSnapshot, virtualSourceIDs, virtualCollections, catalogScope, appleMusicName,
                     genericSourceName] in
                    // 带 Apple Music 虚拟集合的源仍按内存里的歌建,只挑出这些源的歌(在主线程外挑)。
                    let catalogMemorySongs = virtualSourceIDs.isEmpty
                        ? []
                        : songsSnapshot.filter { virtualSourceIDs.contains($0.sourceID) }
                    do {
                        return try await catalogReader.folderIndex { catalog, isCancelled in
                            try LibraryFolderIndexBuilder.build(
                                sources: descriptors,
                                catalog: LibraryFolderCatalogInput(
                                    catalog: catalog,
                                    kinds: catalogScope.kinds,
                                    ordersSpokenWordLikeShelf: false,
                                    sourceID: catalogScope.sourceID
                                ),
                                unlistedSource: { sourceID in
                                    guard catalogScope.sourceID == nil || catalogScope.sourceID == sourceID else { return nil }
                                    return LibraryFolderUnlistedSource.descriptor(
                                        sourceID: sourceID, appleMusicName: appleMusicName, genericName: genericSourceName
                                    )
                                },
                                memorySongs: catalogMemorySongs,
                                virtualCollections: virtualCollections,
                                isCancelled: isCancelled
                            )
                        }
                    } catch is CancellationError {
                        return nil
                    } catch {
                        plog("⚠️ Song list folder index from catalog failed, using memory: \(error)")
                        return nil
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let prepared: LibraryFolderIndex
            if let catalogPrepared {
                prepared = catalogPrepared
            } else {
                prepared = await folderIndexStore.index(
                    version: version,
                    sources: descriptors,
                    songs: songsSnapshot,
                    virtualCollections: virtualCollections
                )
            }
            guard !Task.isCancelled,
                  browseMode == .folder,
                  folderIndexGeneration == generation,
                  folderSourceRevision == sourceRevision,
                  songListVersion.collectionRevision == collectionRevision,
                  library.playlistCollectionRevision == playlistRevision
            else { return }
            folderCache.publish(prepared)
            #if os(iOS) && DEBUG
            LibrarySectionSwitchTrace.mark("folder index built")
            #endif
            if let reuseKey {
                Self.releaseOffMain(LibraryFolderIndexReuseCache.shared.store(prepared, for: reuseKey))
            }
            if selection.isActive, !selection.isEmpty {
                let validIDs = listCache.isEmpty
                    ? Set(songs.lazy.map(\.id))
                    : Set(listCache.orderedSongIDs)
                selection.prune(to: validIDs)
            }
        }
    }

    /// 整库的目录索引是照哪一份输入建的(按源看的歌曲页不复用,返回 nil)。只在动作里读,
    /// 不进 body,整库的这几个版本号变了不会让列表重画。
    private var folderIndexReuseKey: LibraryFolderIndexReuseKey? {
        guard case .library = scope else { return nil }
        return LibraryFolderIndexReuseKey(
            songsRevision: library.musicSongsRevision,
            collectionRevision: songListVersion.collectionRevision,
            replacementToken: songListVersion.replacementToken,
            virtualCollectionRevision: library.playlistCollectionRevision,
            hierarchyRevision: scanService.folderHierarchyRevision,
            sources: configuredFolderSourceDescriptors,
            catalogRevision: library.folderIndexCatalogRevision
        )
    }

    /// 按目录建文件夹索引时的范围,与 `Scope.songs(in:sources:)` 同一口径:整库是音乐
    /// (`musicSongs`),按源看是这个源的可见歌去掉有声与环境音(有声书服务器的源全要)。
    private var folderCatalogScope: SongListFolderCatalogScope {
        switch scope {
        case .library:
            return SongListFolderCatalogScope(kinds: [.music], sourceID: nil)
        case .source(let sourceID):
            return SongListFolderCatalogScope(
                kinds: scope.showsAudiobookshelfContents(in: sourcesStore) ? nil : [.music, .collectionOnly],
                sourceID: sourceID
            )
        }
    }

    /// 目录版式下,上一个歌曲页建好的整库目录索引还对得上就在出现的这一帧摆出来。
    ///
    /// 极简导航换分类会把歌曲页整个换掉,页里自己的索引跟着没了;不复用的话每次切回来都先转圈、
    /// 等后台把整库重新分一遍目录(大曲库要好几秒),这段时间页上是空的。对不上(歌换过、源改过)
    /// 时照旧在后台重建,不在主线程上建。
    private func publishReusableFolderIndex() -> Bool {
        guard browseMode == .folder, !folderCache.hasIndex,
              let key = folderIndexReuseKey,
              let index = LibraryFolderIndexReuseCache.shared.index(for: key) else { return false }
        folderCache.publish(index)
        #if os(iOS) && DEBUG
        LibrarySectionSwitchTrace.mark("folder index reused")
        #endif
        return true
    }

    /// 这次替换没动目录结构(只改了标签):手里这份索引还是对的,留给下一页的那份也跟着记到新令牌下。
    private func carryReusableFolderIndex(from previousToken: UUID, to token: UUID) {
        guard browseMode == .folder, let index = folderCache.index,
              let key = folderIndexReuseKey, key.replacementToken == token else { return }
        LibraryFolderIndexReuseCache.shared.rekey(
            index,
            from: key.replacingToken(previousToken),
            to: key
        )
    }

    /// 换下来的整库索引挪到后台释放,不在主线程上拆。
    private static func releaseOffMain(_ index: LibraryFolderIndex?) {
        guard let index else { return }
        Task.detached(priority: .utility) { withExtendedLifetime(index) {} }
    }

    /// Build sorting, IDs, membership, and aggregates away from the main actor.
    /// The main actor only swaps the completed immutable snapshot reference.
    private func scheduleSortedRecompute(
        delay: Duration? = nil,
        pruneRowModels: Bool,
        isExplicitSort: Bool = false
    ) {
        if !isExplicitSort, let explicitGeneration = sortProgress.generation {
            sortFeedbackTask?.cancel()
            sortFeedbackTask = nil
            sortFeedbackDeadline = nil
            let cancelledOrder = sortProgress.order ?? sortOrder.libraryOrder
            _ = sortProgress.cancel(generation: explicitGeneration)
            SongListPerformanceSignpost.sortCancelled(
                generation: explicitGeneration,
                order: cancelledOrder.rawValue
            )
        }
        sortGeneration &+= 1
        let generation = sortGeneration
        let songsSnapshot = songs
        let order = sortOrder
        let snapshotVersion = songListVersion
        let sortValues = songListSortValues
        let sortValuesVersion = self.sortValuesVersion
        let scopeKey = scope.snapshotCacheKey
        pendingSnapshot = nil
        pendingSnapshotPrunesRows = false
        pendingSnapshotIsExplicitSort = false
        pendingSnapshotGeneration = 0
        pendingSnapshotOrder = nil
        activeSortIsExplicit = isExplicitSort
        sortRequestActive = true
        SongListPerformanceSignpost.sortIntent(
            generation: generation,
            count: songsSnapshot.count,
            order: order.rawValue
        )
        if isExplicitSort, !showsFolderBrowser {
            beginSortFeedback(generation: generation, order: order.libraryOrder)
        }

        sortTask?.cancel()
        sortTask = Task { @MainActor in
            var didPublishOrQueue = false
            defer {
                if sortGeneration == generation, !didPublishOrQueue {
                    finishSortWithoutPublication(
                        generation: generation,
                        order: order.libraryOrder,
                        isExplicitSort: isExplicitSort
                    )
                }
            }
            // Give a system Menu one main-run-loop turn to dismiss. Cache hits
            // are still immediate; there is no fixed 350 ms latency floor.
            await Task.yield()
            SongListPerformanceSignpost.sortDispatched(
                generation: generation,
                order: order.rawValue
            )
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard let prepared = await SongListSnapshotStore.shared.snapshot(
                scopeKey: scopeKey,
                version: snapshotVersion,
                order: order.libraryOrder,
                songs: songsSnapshot,
                sortValues: sortValues,
                sortValuesVersion: sortValuesVersion,
                cancelSuperseded: true
            ) else { return }
            // A delayed feedback task whose 200 ms deadline elapsed while the
            // worker was sorting must get a main-actor turn before publication
            // can cancel it. Fast cache hits still publish without feedback.
            await Task.yield()
            guard !Task.isCancelled,
                  sortGeneration == generation,
                  sortOrder == order,
                  songListVersion == snapshotVersion,
                  self.sortValuesVersion.revision(for: order.libraryOrder)
                    == sortValuesVersion.revision(for: order.libraryOrder)
            else { return }
            await revealOverdueSortFeedbackBeforePublication(
                generation: generation,
                order: order.libraryOrder,
                songCount: prepared.rows.count
            )
            guard !Task.isCancelled, sortGeneration == generation else { return }
            publishPreparedSnapshot(
                prepared,
                pruneRowModels: pruneRowModels,
                isExplicitSort: isExplicitSort,
                generation: generation,
                order: order.libraryOrder
            )
            didPublishOrQueue = true
        }
    }

    private func publishPreparedSnapshot(
        _ snapshot: SongListSnapshot,
        pruneRowModels: Bool,
        isExplicitSort: Bool,
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        if isListInteracting, !listCache.isEmpty {
            pendingSnapshot = snapshot
            pendingSnapshotPrunesRows = pruneRowModels
            pendingSnapshotIsExplicitSort = isExplicitSort
            pendingSnapshotGeneration = generation
            pendingSnapshotOrder = order
            if isExplicitSort,
               sortProgress.markWaitingForPublication(generation: generation) {
                SongListPerformanceSignpost.sortWaitingForPublication(
                    generation: generation,
                    order: order.rawValue
                )
            }
            return
        }
        publishSnapshotWithoutAnimation(
            snapshot,
            pruneRowModels: pruneRowModels,
            isExplicitSort: isExplicitSort,
            generation: generation,
            order: order
        )
    }

    private func updateListInteraction(for phase: ScrollPhase) {
        if phase == .tracking || phase == .interacting { songLocation.cancel() }
        switch phase {
        case .tracking, .interacting, .decelerating:
            guard !isListInteracting else { return }
            isListInteracting = true
        case .idle:
            if isListInteracting {
                isListInteracting = false
            }
            guard let pendingSnapshot else { return }
            let pruneRowModels = pendingSnapshotPrunesRows
            let isExplicitSort = pendingSnapshotIsExplicitSort
            let generation = pendingSnapshotGeneration
            guard let order = pendingSnapshotOrder else { return }
            self.pendingSnapshot = nil
            pendingSnapshotPrunesRows = false
            pendingSnapshotIsExplicitSort = false
            pendingSnapshotGeneration = 0
            pendingSnapshotOrder = nil
            publishSnapshotWithoutAnimation(
                pendingSnapshot,
                pruneRowModels: pruneRowModels,
                isExplicitSort: isExplicitSort,
                generation: generation,
                order: order
            )
        case .animating:
            break
        }
    }

    private func publishSnapshotWithoutAnimation(
        _ snapshot: SongListSnapshot,
        pruneRowModels: Bool,
        isExplicitSort: Bool,
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            listCache.publish(snapshot, pruneRowModels: pruneRowModels) {
                library.unobservedVisibleSong(id: $0)
            }
        }
        if selection.isActive, !selection.isEmpty {
            selection.prune(to: snapshot.songIDs)
        }
        SongListPerformanceSignpost.sortPublished(
            generation: generation,
            count: snapshot.rows.count,
            order: order.rawValue
        )
        if isExplicitSort {
            finishSortAfterPublication(generation: generation, order: order)
        } else if sortGeneration == generation {
            sortRequestActive = false
            activeSortIsExplicit = false
        }
    }

    private func beginSortFeedback(
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        SongListPerformanceSignpost.sortFeedbackScheduled(
            generation: generation,
            order: order.rawValue
        )
        sortFeedbackTask?.cancel()
        let updatedVisibleFeedback = sortProgress.begin(
            generation: generation,
            order: order
        )
        if updatedVisibleFeedback {
            sortFeedbackDeadline = nil
            SongListPerformanceSignpost.sortFeedbackShown(
                generation: generation,
                order: order.rawValue,
                updated: true
            )
            announceSortStatus(sortProgressMessage(for: order))
            return
        }

        sortFeedbackDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))

        sortFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard sortProgress.reveal(generation: generation) else { return }
            SongListPerformanceSignpost.sortFeedbackShown(
                generation: generation,
                order: order.rawValue,
                updated: false
            )
            announceSortStatus(sortProgressMessage(for: order))
        }
    }

    private func revealOverdueSortFeedbackBeforePublication(
        generation: Int,
        order: LibrarySongSortOrder,
        songCount: Int
    ) async {
        guard sortProgress.generation == generation,
              !sortProgress.isVisible,
              let sortFeedbackDeadline else { return }
        let now = ContinuousClock.now
        if now < sortFeedbackDeadline {
            let remaining = now.duration(to: sortFeedbackDeadline)
            // A large snapshot can finish sorting quickly but still spend well
            // over the threshold in SwiftUI publication. Give that known-cost
            // path real feedback; genuinely small/fast lists still publish
            // immediately unless they are within one display opportunity.
            guard SongListSortProgressState.shouldAwaitFeedbackDeadline(
                songCount: songCount
            ) || remaining <= .milliseconds(34) else { return }
            try? await Task.sleep(for: remaining)
        }
        guard sortProgress.generation == generation,
              !sortProgress.isVisible,
              sortProgress.reveal(generation: generation) else { return }
        SongListPerformanceSignpost.sortFeedbackShown(
            generation: generation,
            order: order.rawValue,
            updated: false
        )
        announceSortStatus(sortProgressMessage(for: order))
        // The deadline may have elapsed while a system Menu owned the main
        // run loop. Keep the newly revealed status for at least one display
        // opportunity before swapping the prepared snapshot.
        try? await Task.sleep(for: .milliseconds(34))
    }

    private func finishSortWithoutPublication(
        generation: Int,
        order: LibrarySongSortOrder,
        isExplicitSort: Bool
    ) {
        sortRequestActive = false
        activeSortIsExplicit = false
        guard isExplicitSort else { return }
        sortFeedbackTask?.cancel()
        sortFeedbackDeadline = nil
        let wasVisible = sortProgress.isVisible
        guard sortProgress.cancel(generation: generation) else { return }
        SongListPerformanceSignpost.sortCancelled(
            generation: generation,
            order: order.rawValue
        )
        if wasVisible {
            announceSortStatus(String(localized: "song_sort_progress_cancelled"))
        }
    }

    private func finishSortAfterPublication(
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        guard sortGeneration == generation else { return }
        sortRequestActive = false
        activeSortIsExplicit = false
        sortFeedbackTask?.cancel()
        sortFeedbackDeadline = nil
        let shouldAnnounceCompletion = sortProgress.markPublished(generation: generation)
        if shouldAnnounceCompletion {
            announceSortStatus(sortCompletedMessage(for: order))
        }
        _ = sortProgress.finish(generation: generation)
    }

    private func cancelExplicitSortForSelection() {
        cancelExplicitSort(announceCancellation: true)
    }

    private func cancelExplicitSortForNavigation() {
        cancelExplicitSort(announceCancellation: false)
    }

    private func cancelExplicitSort(announceCancellation: Bool) {
        guard activeSortIsExplicit
                || pendingSnapshotIsExplicitSort
                || sortProgress.generation != nil else { return }
        let cancelledGeneration = sortGeneration
        let cancelledOrder = sortProgress.order ?? sortOrder.libraryOrder
        let wasVisible = sortProgress.isVisible
        sortGeneration &+= 1
        sortTask?.cancel()
        sortTask = nil
        sortFeedbackTask?.cancel()
        sortFeedbackTask = nil
        sortFeedbackDeadline = nil
        sortRequestActive = false
        activeSortIsExplicit = false
        if pendingSnapshotIsExplicitSort {
            pendingSnapshot = nil
            pendingSnapshotPrunesRows = false
            pendingSnapshotIsExplicitSort = false
            pendingSnapshotGeneration = 0
            pendingSnapshotOrder = nil
        }
        _ = sortProgress.cancel(generation: cancelledGeneration)
        SongListPerformanceSignpost.sortCancelled(
            generation: cancelledGeneration,
            order: cancelledOrder.rawValue
        )
        if announceCancellation, wasVisible {
            announceSortStatus(String(localized: "song_sort_progress_cancelled"))
        }
        let scopeKey = scope.snapshotCacheKey
        Task {
            await SongListSnapshotStore.shared.cancelPending(scopeKey: scopeKey)
        }
    }

    private func announceSortStatus(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }

    private func handleLocationRequest(_ request: SongLibraryLocationRequest?) {
        guard let request else { return }
        guard case .library = scope,
              library.visibleSong(id: request.songID) != nil else {
            locationRequest = nil
            return
        }

        selection.deactivate()
        searchText = ""
        songFilter = .all
        #if os(iOS)
        appliedSearchText = ""
        #endif
        #if os(macOS)
        selectedSourceID = nil
        #endif

        locateSong(request.songID)
        locationRequest = nil
    }

    private func playSong(_ song: Song) {
        if showsCatalogList {
            // 目录列表:按显示顺序取好整份 id(播放器的整库请求只认 id),再从这首起放。
            withCatalogSongIDs { ids in
                guard let index = ids.firstIndex(of: song.id) else { return }
                plog("🎶 SongList setQueue visible=\(ids.count) start='\(song.title)' catalog")
                SiriMediaInteractionDonor.donate(song: song)
                Task { await player.play(queueIDs: ids, startingAt: index, order: .rotatedToStart, playableOnly: false) }
            }
            return
        }
        let ids = filteredSongIDs
        guard let index = ids.firstIndex(of: song.id) else { return }
        plog("🎶 SongList setQueue visible=\(ids.count) start='\(song.title)'")
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queueIDs: ids, startingAt: index, order: .rotatedToStart, playableOnly: false) }
    }

    /// 把眼前这份列表直接打乱播放。专辑、歌单、艺人详情页早就各有一个随机
    /// 播放按钮, 唯独「歌曲」这份总列表没有 —— 只能先随便点开一首歌进播放页,
    /// 再去底部那排控件里把随机播放打开。
    private func shuffleVisibleSongs() {
        if showsCatalogList {
            withCatalogSongIDs { ids in
                guard ids.count > 1 else { return }
                plog("🎶 SongList shuffleAll visible=\(ids.count) catalog")
                player.shuffleEnabled = true
                Task { await player.play(queueIDs: ids, order: .shuffled) }
            }
            return
        }
        let ids = filteredSongIDs
        guard ids.count > 1 else { return }
        plog("🎶 SongList shuffleAll visible=\(ids.count)")
        player.shuffleEnabled = true
        Task { await player.play(queueIDs: ids, order: .shuffled) }
    }

    /// 极简页头的「全部播放」：按眼前的顺序从第一首放起。
    private func playVisibleSongs() {
        if showsCatalogList {
            withCatalogSongIDs { ids in
                plog("🎶 SongList playAll visible=\(ids.count) catalog")
                player.shuffleEnabled = false
                Task { await player.play(queueIDs: ids, order: .asGiven) }
            }
            return
        }
        let ids = filteredSongIDs
        guard !ids.isEmpty else { return }
        plog("🎶 SongList playAll visible=\(ids.count)")
        player.shuffleEnabled = false
        Task { await player.play(queueIDs: ids, order: .asGiven) }
    }
}

/// A lazy stack avoids asking SwiftUI's `List` bridge to register every stable
/// position up front. With a five-digit library that registration alone can
/// block the main thread for several seconds when entering flat mode, even
/// though only a screenful of rows is visible.
private struct IOSSongIndexScrollRequest: Equatable {
    let id = UUID()
    let rowOffset: Int
    let rowOrderRevision: Int
}

private struct IOSSongListContainer: View, @MainActor Equatable {
    let cache: SongListCache
    let rowOrderRevision: Int
    let sectionIndexEntries: [SongListSectionIndexEntry]
    let locatedSongID: String?
    let locationRequestID: UUID?
    @Environment(\.songListLocation) private var location
    @Environment(\.songListAppearance) private var appearance
    let selection: SongSelectionModel
    let showsListeningIntents: Bool
    let onPlay: (Song) -> Void

    @State private var indexScrollRequest: IOSSongIndexScrollRequest?
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    /// 按位置跳转时的对齐方式。系统只认挂在 `scrollPosition` 修饰符上的锚点，`scrollTo(id:anchor:)`
    /// 自己带的锚点不起作用（按「滚到刚好露出」处理，目标停在底部）；每次跳之前先换好。
    @State private var scrollAnchor: UnitPoint = .top
    /// 滚到哪个字母：只有字母条读它。
    @State private var indexTracker = LibraryIndexRailTracker()
    /// 系统把工具栏竖排到右侧时(iPhone Duo 等),字母索引紧挨着那一列系统按钮:
    /// 往里让一段,拖着索引快速定位时手指不会滑到返回、更多这些键上。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge

    /// 字母索引离容器右缘多远;行尾给索引的让位跟着一起加。
    private var sectionIndexTrailingInset: CGFloat {
        verticalBarEdge == .trailing ? 10 : 2
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cache === rhs.cache
            && lhs.rowOrderRevision == rhs.rowOrderRevision
            && lhs.sectionIndexEntries == rhs.sectionIndexEntries
            && lhs.locatedSongID == rhs.locatedSongID
            && lhs.locationRequestID == rhs.locationRequestID
            && lhs.selection === rhs.selection
            && lhs.showsListeningIntents == rhs.showsListeningIntents
    }

    var body: some View {
        let railModel = LibraryIndexRailModel(songEntries: sectionIndexEntries, rowCount: cache.positionCount)
        return ZStack(alignment: .trailing) {
            ScrollView {
                if showsListeningIntents {
                    // 不放进下面的懒加载栈:它带导航目标,而且只有这一份。
                    StartListeningShelf(horizontalInset: 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
                positionStack
            }
            .scrollPosition($scrollPosition, anchor: scrollAnchor)
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.5) { positions in
                guard let top = positions.min() else { return }
                indexTracker.lastTopPosition = top
                guard showsSectionIndex else { return }
                indexTracker.update(railModel.label(containing: top))
            }
            // iPhone Duo 竖栏：行和字母索引都停在竖栏左侧，「开始听」的横滑一排铺到屏幕右缘。
            .pmExtendsUnderVerticalBar()
            .background(songListBackground)
            // 量的是行所在的这个滚动容器, 不是整屏。字母索引是盖在容器右缘的
            // overlay, 行靠 trailingPadding 给它让位 (16 → 42), 对齐列排在
            // 让位之内, 不会和索引条打架。
            .songRowColumnsContainer()

            if showsSectionIndex {
                // 和专辑、艺人页同一条字母条；行尾让出 40，可按的宽度照旧 48。
                LibraryIndexRail(
                    entries: railModel.entries,
                    tracker: indexTracker,
                    hitWidth: 48,
                    countText: { LibraryCountText.formattedSongs($0) },
                    preview: { _ in EmptyView() }
                ) { entry in
                    guard (0..<cache.positionCount).contains(entry.target) else { return }
                    indexScrollRequest = IOSSongIndexScrollRequest(
                        rowOffset: entry.target,
                        rowOrderRevision: rowOrderRevision
                    )
                }
                .accessibilityIdentifier("songList.alphabetIndex")
                .padding(.trailing, sectionIndexTrailingInset)
                // 「开始听」那一行的标题右端有「全部」，索引从它下面开始，两者不叠在一起。
                .padding(.top, showsListeningIntents ? 48 : 0)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .task(id: indexScrollRequest) {
            guard let request = indexScrollRequest else { return }
            scrollAnchor = .top
            await Task.yield()
            guard !Task.isCancelled,
                  request.rowOrderRevision == rowOrderRevision,
                  (0..<cache.positionCount).contains(request.rowOffset) else {
                return
            }
            scrollPosition.scrollTo(id: request.rowOffset, anchor: .top)
        }
        .task(id: SongLocationScrollTrigger(
            requestID: locationRequestID,
            songID: locatedSongID,
            rowOrderRevision: rowOrderRevision
        )) {
            guard location?.needsScroll != false, let locatedSongID,
                  let rowOffset = cache.position(of: locatedSongID) else { return }
            scrollAnchor = .center
            await Task.yield()
            guard !Task.isCancelled,
                  self.locatedSongID == locatedSongID,
                  rowOrderRevision == cache.rowOrderRevision else { return }
            scrollPosition.scrollTo(id: rowOffset, anchor: .center)
        }
        .onChange(of: rowOrderRevision) { _, _ in
            indexScrollRequest = nil
            // 换了排序：露出的还是那几个位置，系统不会再报，按刚才的位置重新认。
            indexTracker.update(indexTracker.lastTopPosition.flatMap(railModel.label(containing:)))
        }
        .pmAnimation(.control, value: showsSectionIndex)
        #if DEBUG
        .task { await scrollToDebugPositionIfRequested() }
        #endif
    }

    /// 三种外观都是懒加载栈，一个位置一个子视图、一个滚动目标，字母索引与定位按位置跳过去。
    /// 时间线与封面换成 `SongTimelineStack`：量一次行宽、在背后画中轴，首尾给伸出槽位的封面留地方。
    @ViewBuilder
    private var positionStack: some View {
        if appearance == .list {
            LazyVStack(spacing: 0) {
                positionSlots
            }
            // Keeping a strict one-item-to-one-scroll-target mapping lets
            // the lazy stack resolve a distant ID directly. If a ForEach
            // element expands into both a row and a divider, SwiftUI may
            // walk thousands of intermediate children.
            .scrollTargetLayout()
        } else {
            SongTimelineStack(appearance: appearance) {
                positionSlots
            }
        }
    }

    private var positionSlots: some View {
        ForEach(0..<cache.positionCount, id: \.self) { position in
            IOSSongListPositionSlot(
                position: position,
                isLast: position == cache.positionCount - 1,
                trailingPadding: showsSectionIndex ? 40 + sectionIndexTrailingInset : 16,
                cache: cache,
                locatedSongID: locatedSongID,
                selection: selection,
                onPlay: onPlay
            )
        }
    }

    #if DEBUG
    /// 截图钩子：`PRIMUSE_DEBUG_SONG_LIST_POSITION=<位置>` 打开歌曲页后滚到这一首（从 0 数），
    /// `PRIMUSE_DEBUG_SONG_LIST_ANCHOR=<0…1>` 让它停在可视区的这个高度，用来截滚动途中某一帧。
    private func scrollToDebugPositionIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["PRIMUSE_DEBUG_SONG_LIST_POSITION"], let position = Int(raw),
              (0..<cache.positionCount).contains(position) else { return }
        let anchor = UnitPoint(x: 0.5, y: environment["PRIMUSE_DEBUG_SONG_LIST_ANCHOR"].flatMap(Double.init) ?? 0)
        scrollAnchor = anchor
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        scrollPosition.scrollTo(id: position, anchor: anchor)
    }
    #endif

    /// 字母索引只在列表外观里有；多选时收起。时间线与封面以中轴居中、左右对称，
    /// 索引那一条要么把中轴挤偏、卡片收窄，要么压在右侧一列的封面上截走点按
    /// （它按下就跳，没有拖动门槛）。这两种外观里快速翻找靠拖滚动条。
    private var showsSectionIndex: Bool {
        appearance == .list
            && !selection.isActive
            && cache.positionCount >= 24
            && sectionIndexEntries.lazy.filter(\.isAvailable).count > 1
    }

    private var songListBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}

/// The outer lazy stack must see one stable child for every position. Keeping
/// the separator inside the slot preserves constant target cardinality and
/// allows far-away alphabet jumps without resolving all preceding rows.
private struct IOSSongListPositionSlot: View {
    let position: Int
    let isLast: Bool
    let trailingPadding: CGFloat
    let cache: SongListCache
    let locatedSongID: String?
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void
    @Environment(\.songRowStyle) private var rowStyle
    @Environment(\.songListAppearance) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            IOSSongListPositionRow(
                position: position,
                cache: cache,
                locatedSongID: locatedSongID,
                selection: selection,
                onPlay: onPlay
            )
            // 时间线与封面的左右留白、行距都由 `SongTimelineStack` 与固定的槽位高度给。
            .padding(.leading, appearance == .list ? 16 : 0)
            .padding(.trailing, appearance == .list ? trailingPadding : 0)
            .padding(.vertical, appearance == .list ? 4 : 0)

            if appearance == .list {
                Divider()
                    .padding(.leading, rowStyle.separatorLeadingInset)
                    .opacity(isLast ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Filtered flat lists keep their own lightweight row ordering. The full-list
/// container remains position based for five-digit libraries, while this
/// projection uses stable song IDs so excluded rows never leave empty slots.
private struct IOSSongListFilteredContainer: View, @MainActor Equatable {
    let projection: SongListProjection
    let projectionRevision: Int
    /// 页内搜索词: 换了词就是另一份结果, 修订号不会跟着变。
    let query: String
    let rowOrderRevision: Int
    let cache: SongListCache
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void
    @Environment(\.songRowStyle) private var rowStyle
    @Environment(\.songListAppearance) private var appearance

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectionRevision == rhs.projectionRevision
            && lhs.query == rhs.query
            && lhs.rowOrderRevision == rhs.rowOrderRevision
            && lhs.cache === rhs.cache
            && lhs.selection === rhs.selection
    }

    var body: some View {
        ScrollView {
            if appearance == .list {
                LazyVStack(spacing: 0) {
                    ForEach(projection.rows) { row in
                        VStack(spacing: 0) {
                            projectedRow(row)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)

                            if row.offset < projection.rows.count - 1 {
                                Divider()
                                    .padding(.leading, rowStyle.separatorLeadingInset)
                            }
                        }
                        .id(row.id)
                    }
                }
            } else {
                SongTimelineStack(appearance: appearance) {
                    ForEach(projection.rows) { row in
                        projectedRow(row)
                            .id(row.id)
                    }
                }
            }
        }
        .pmExtendsUnderVerticalBar()
        .background(songListBackground)
        .songRowColumnsContainer()
    }

    private func projectedRow(_ row: SongListRowIdentity) -> some View {
        IOSSongListProjectedRow(
            songID: row.id,
            ordinal: row.offset + 1,
            totalCount: projection.rows.count,
            cache: cache,
            selection: selection,
            onPlay: onPlay
        )
    }

    private var songListBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}

private struct IOSSongListProjectedRow: View {
    @Environment(MusicLibrary.self) private var library

    let songID: String
    let ordinal: Int
    let totalCount: Int
    let cache: SongListCache
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    @ViewBuilder
    var body: some View {
        if let model = cache.rowModel(
            id: songID,
            song: library.unobservedVisibleSong(id: songID)
        ) {
            IOSSongListRow(model: model, ordinal: ordinal, totalCount: totalCount, selection: selection, onPlay: onPlay)
                .accessibilityIdentifier("songRow.\(songID)")
        }
    }
}

#if os(iOS)
private struct SongBrowseModeTransitionOverlay: View {
    let mode: LibrarySongBrowseMode

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("library_browse_switch_loading")
                .font(.subheadline.weight(.semibold))
            Text(modeLabel)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).opacity(0.94))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("songBrowseModeTransition")
        .zIndex(1)
    }

    private var modeLabel: LocalizedStringKey {
        mode == .flat ? "library_browse_flat" : "library_browse_folder"
    }
}
#endif

private enum LibraryFolderNodePresentation {
    static var background: Color {
        #if os(macOS)
        return PMColor.bg
        #else
        return Color(.systemBackground)
        #endif
    }

    static func title(for node: LibraryFolderNode) -> String {
        switch node.kind {
        case .source:
            return node.displayName ?? String(localized: "source_label")
        case .scanRoot:
            return node.displayName ?? String(localized: "library_folder_scan_root")
        case .folder:
            return node.displayName ?? String(localized: "library_folder_scan_root")
        case .librarySongs:
            return node.displayName ?? String(localized: "library_folder_apple_music_library_songs")
        case .playlist:
            return node.displayName ?? String(localized: "library_folder_apple_music_unnamed_playlist")
        case .notInPlaylist:
            return node.displayName ?? String(localized: "library_folder_apple_music_not_in_playlist")
        case .uncategorized:
            return String(localized: "library_folder_uncategorized")
        case .other:
            return String(localized: "library_folder_other")
        }
    }

    static func icon(for kind: LibraryFolderNodeKind) -> String {
        switch kind {
        case .source: return "externaldrive.connected.to.line.below"
        case .scanRoot: return "externaldrive.fill.badge.checkmark"
        case .folder: return "folder.fill"
        case .librarySongs: return "music.note.house.fill"
        case .playlist: return "music.note.list"
        case .notInPlaylist: return "tray.fill"
        case .uncategorized: return "tray.fill"
        case .other: return "questionmark.folder.fill"
        }
    }

    static func songCount(_ count: Int) -> String {
        LibraryCountText.formattedSongs(count)
    }

    static func accessibilityToken(for id: LibraryFolderNodeID) -> String {
        // Swift's `hashValue` is deliberately randomized per process. A small
        // deterministic digest keeps UI automation stable without exposing a
        // source ID or normalized path through the accessibility identifier.
        var digest: UInt64 = 0xcbf29ce484222325
        let identity = [
            id.sourceID,
            id.kind.rawValue,
            id.normalizedRelativePath,
        ].joined(separator: "\u{1F}")
        for byte in identity.utf8 {
            digest ^= UInt64(byte)
            digest &*= 0x100000001b3
        }
        return String(digest, radix: 16)
    }
}

private struct LibraryFolderRootView: View {
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let rootSourceID: String?
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder
    var showsListeningIntents = false

    var body: some View {
        ScrollView {
            if showsListeningIntents {
                StartListeningShelf(horizontalInset: 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            LibraryFolderRootContent(
                folderCache: folderCache,
                listCache: listCache,
                rootSourceID: rootSourceID,
                selection: selection,
                sortOrder: $sortOrder,
                onOpenFolder: nil
            )
            .padding(.horizontal, 12)
            #if os(iOS)
            .padding(.bottom, 16)
            #else
            .padding(.bottom, 112)
            #endif
        }
        .pmExtendsUnderVerticalBar()
        .background(LibraryFolderNodePresentation.background.ignoresSafeArea())
    }
}

private struct LibraryFolderRootContent: View {
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let rootSourceID: String?
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder
    let onOpenFolder: ((LibraryFolderNodeID) -> Void)?

    var body: some View {
        let nodes = folderCache.rootNodes(sourceID: rootSourceID)
        if nodes.isEmpty {
            ContentUnavailableView(
                "no_songs",
                systemImage: "folder",
                description: Text("no_songs_desc")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(nodes) { node in
                    LibraryFolderNodeBranch(
                        nodeID: node.id,
                        depth: 0,
                        folderCache: folderCache,
                        listCache: listCache,
                        selection: selection,
                        sortOrder: $sortOrder,
                        onOpenFolder: onOpenFolder
                    )
                    .id(node.id)
                }
            }
        }
    }
}

#if os(macOS)
private struct MacLibraryFolderInlineContent: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(ThemeService.self) private var theme
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(MetadataBackfillService.self) private var backfill

    let folderPath: [LibraryFolderNodeID]
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder
    let onOpenFolder: (LibraryFolderNodeID) -> Void
    let onNavigate: (LibraryFolderNodeID?) -> Void
    @State private var maintenance = LibraryFolderMaintenanceModel()

    @ViewBuilder
    var body: some View {
        if let nodeID = folderPath.last,
           let node = folderCache.node(withID: nodeID) {
            LazyVStack(alignment: .leading, spacing: 0) {
                navigationBar(node)

                LibraryFolderMaintenanceStatus(sourceID: nodeID.sourceID, model: maintenance)

                let children = folderCache.children(of: nodeID)
                if !children.isEmpty {
                    sectionHeader("library_browse_folder")
                    ForEach(children) { child in
                        LibraryFolderNodeBranch(
                            nodeID: child.id,
                            depth: 0,
                            folderCache: folderCache,
                            listCache: listCache,
                            selection: selection,
                            sortOrder: $sortOrder,
                            onOpenFolder: onOpenFolder
                        )
                        .id(child.id)
                    }
                }

                if !visibleSongIDs.isEmpty {
                    sectionHeader("tab_songs")
                    ForEach(Array(visibleSongIDs.enumerated()), id: \.element) { index, songID in
                        LibraryFolderSongRow(
                            songID: songID,
                            ordinal: index + 1,
                            totalCount: visibleSongIDs.count,
                            orderedIDs: { visibleSongIDs },
                            listCache: listCache,
                            selection: selection,
                            onPlay: playSong
                        )
                        .id(SongLocationScrollID(songID: songID))
                    }
                }

                if children.isEmpty && visibleSongIDs.isEmpty {
                    ContentUnavailableView(
                        "no_songs",
                        systemImage: "folder",
                        description: Text("no_songs_desc")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
        } else {
            ContentUnavailableView(
                "no_songs",
                systemImage: "folder.badge.questionmark",
                description: Text("no_songs_desc")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
    }

    private func navigationBar(_ node: LibraryFolderNode) -> some View {
        HStack(spacing: 10) {
            Button {
                onNavigate(folderPath.dropLast().last)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(PMColor.glassBtn, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PMColor.text)
            .help(parentTitle)
            .accessibilityLabel(Text(verbatim: parentTitle))

            Divider()
                .frame(height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Button {
                        onNavigate(nil)
                    } label: {
                        Label("library_browse_folder", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.uiAccentColor)

                    ForEach(folderPath.indices, id: \.self) { index in
                        if let pathNode = folderCache.node(withID: folderPath[index]) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(PMColor.textFaint)
                                .accessibilityHidden(true)

                            if index == folderPath.count - 1 {
                                Text(verbatim: LibraryFolderNodePresentation.title(for: pathNode))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(PMColor.text)
                            } else {
                                Button {
                                    onNavigate(pathNode.id)
                                } label: {
                                    Text(verbatim: LibraryFolderNodePresentation.title(for: pathNode))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.uiAccentColor)
                            }
                        }
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            }
            .pmStopsAtVerticalBar()
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: LibraryFolderNodePresentation.songCount(node.descendantSongCount))
                .font(.caption)
                .foregroundStyle(PMColor.textMuted)
                .monospacedDigit()
                .fixedSize()

            Button(action: playAllSongsInFolder) {
                Label("play_all", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.textOnAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(theme.uiAccentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(actionSongIDs.isEmpty || selection.isActive)

            if let actions = LibraryFolderMaintenanceActions.make(
                nodeID: node.id,
                index: folderCache.index,
                songIDs: actionSongIDs,
                model: maintenance,
                scanService: scanService,
                sourceManager: sourceManager,
                sourcesStore: sourcesStore,
                library: library,
                scraperService: scraperService,
                backfill: backfill
            ) {
                Menu {
                    LibraryFolderMaintenanceMenuItems(actions: actions)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(PMColor.glassBtn, in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(PMColor.text)
                .disabled(selection.isActive)
                .accessibilityLabel(Text("a11y_more_actions"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(PMColor.card, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .padding(.bottom, 4)
    }

    private var parentTitle: String {
        guard let parentID = folderPath.dropLast().last,
              let parent = folderCache.node(withID: parentID) else {
            return String(localized: "library_browse_folder")
        }
        return LibraryFolderNodePresentation.title(for: parent)
    }

    private var visibleSongIDs: [String] {
        guard let nodeID = folderPath.last else { return [] }
        return folderCache.orderedSongIDs(
            in: nodeID,
            scope: .visible,
            listCache: listCache
        )
    }

    private var actionSongIDs: [String] {
        guard let nodeID = folderPath.last else { return [] }
        return folderCache.orderedSongIDs(
            in: nodeID,
            scope: .action,
            listCache: listCache
        )
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.headline)
            .foregroundStyle(PMColor.textMuted)
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func playAllSongsInFolder() {
        let ids = actionSongIDs
        guard let first = ids.lazy.compactMap({ library.unobservedVisibleSong(id: $0) }).first else { return }
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(queueIDs: ids) }
    }

    private func playSong(_ song: Song) {
        let ids = visibleSongIDs
        guard let index = ids.firstIndex(of: song.id) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queueIDs: ids, startingAt: index) }
    }
}
#endif

private struct LibraryFolderNodeBranch: View {
    let nodeID: LibraryFolderNodeID
    let depth: Int
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder
    let onOpenFolder: ((LibraryFolderNodeID) -> Void)?

    @Environment(MusicLibrary.self) private var library
    @State private var albumMetadataSelection: BatchSongSelection?
    @State private var isExpanded = false

    @ViewBuilder
    var body: some View {
        if let node = folderCache.node(withID: nodeID) {
            VStack(spacing: 0) {
                Group {
                    #if os(iOS)
                    HStack(spacing: 0) {
                        rowAction(for: node)
                        if selection.isActive {
                            disclosureButton(for: node)
                        }
                    }
                    #else
                    HStack(spacing: 0) {
                        if onOpenFolder == nil {
                            disclosureButton(for: node)
                        }
                        rowAction(for: node)
                    }
                    #endif
                }
                .padding(.leading, rowIndent)
                .frame(minHeight: 54)

                Divider()
                    .padding(.leading, rowIndent + 54)

                if showsExpandedChildren {
                    LazyVStack(spacing: 0) {
                        ForEach(folderCache.children(of: node.id)) { child in
                            AnyView(LibraryFolderNodeBranch(
                                nodeID: child.id,
                                depth: depth + 1,
                                folderCache: folderCache,
                                listCache: listCache,
                                selection: selection,
                                sortOrder: $sortOrder,
                                onOpenFolder: onOpenFolder
                            ))
                            .id(child.id)
                        }
                    }
                }
            }
        }
    }

    private var rowIndent: CGFloat {
        #if os(iOS)
        CGFloat(min(depth, 6)) * 12
        #else
        CGFloat(min(depth, 8)) * 14
        #endif
    }

    private var showsExpandedChildren: Bool {
        #if os(iOS)
        selection.isActive && isExpanded
        #else
        onOpenFolder == nil && isExpanded
        #endif
    }

    @ViewBuilder
    private func disclosureButton(for node: LibraryFolderNode) -> some View {
        if node.childNodeCount > 0 {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: isExpanded
                ? String(localized: "library_folder_collapse")
                : String(localized: "library_folder_expand")
            ))
            .accessibilityIdentifier(
                "libraryFolderDisclosure.\(LibraryFolderNodePresentation.accessibilityToken(for: node.id))"
            )
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func rowAction(for node: LibraryFolderNode) -> some View {
        ZStack(alignment: .leading) {
            if selection.isActive {
                LibraryFolderSelectionButton(
                    node: node,
                    folderCache: folderCache,
                    listCache: listCache,
                    selection: selection
                )
            } else {
                primaryRowAction(for: node)
                    .buttonStyle(.plain)
            }
        }
        // The menu must outlive the navigation-to-selection content change.
        .contextMenu {
            Button("album_metadata_search", systemImage: "square.stack") {
                albumMetadataSelection = BatchSongSelection(
                    songs: actionSongIDs().compactMap { library.unobservedVisibleSong(id: $0) }
                )
            }
            .disabled(node.descendantSongCount == 0)
            Button {
                selection.activate()
                selection.selectAll(actionSongIDs())
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }
            .disabled(node.descendantSongCount == 0)
        }
        .sheet(item: $albumMetadataSelection) { batch in
            AlbumMetadataView(songs: batch.songs)
        }
        .accessibilityAction(named: Text("batch_select")) {
            selection.activate()
            selection.selectAll(actionSongIDs())
        }
    }

    @ViewBuilder
    private func primaryRowAction(for node: LibraryFolderNode) -> some View {
        #if os(macOS)
        if let onOpenFolder {
            Button {
                onOpenFolder(node.id)
            } label: {
                LibraryFolderNodeLabel(node: node, selectionState: nil)
            }
        } else {
            // macOS folder navigation is state-driven and stays inside the
            // song page. Never fall back to NavigationLink here: it injects a
            // phone-style back control into the native window toolbar.
            LibraryFolderNodeLabel(node: node, selectionState: nil)
        }
        #else
        folderNavigationLink(for: node)
        #endif
    }

    #if os(iOS)
    private func folderNavigationLink(for node: LibraryFolderNode) -> some View {
        NavigationLink {
            LibraryFolderNodeView(
                nodeID: node.id,
                folderCache: folderCache,
                listCache: listCache,
                selection: selection,
                sortOrder: $sortOrder
            )
        } label: {
            LibraryFolderNodeLabel(node: node, selectionState: nil)
        }
    }
    #endif

    private func actionSongIDs() -> [String] {
        folderCache.orderedSongIDs(
            in: nodeID,
            scope: .action,
            listCache: listCache
        )
    }
}

/// A dedicated observation boundary keeps an aggregate folder-state change
/// from rebuilding its expanded descendants. The selection index materializes
/// the descendant set only when the immutable folder/list version changes.
private struct LibraryFolderSelectionButton: View {
    let node: LibraryFolderNode
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel

    var body: some View {
        let songIDs = folderCache.orderedSongIDs(
            in: node.id,
            scope: .action,
            listCache: listCache
        )
        let membership = selection.groupMembership(
            for: node.id,
            version: LibraryFolderSelectionVersion(
                folderRevision: folderCache.revision,
                rowOrderRevision: listCache.rowOrderRevision
            ),
            songIDs: songIDs
        )
        let snapshot = membership.snapshot

        Button {
            selection.toggleGroup(songIDs)
        } label: {
            LibraryFolderNodeLabel(
                node: node,
                selectionState: snapshot.state,
                selectionSongCount: snapshot.songCount
            )
        }
        .buttonStyle(.plain)
        .disabled(snapshot.songCount == 0)
        .accessibilityAddTraits(snapshot.state == .all ? .isSelected : [])
    }
}

private struct LibraryFolderNodeLabel: View {
    @Environment(ThemeService.self) private var theme

    let node: LibraryFolderNode
    let selectionState: SongSelectionModel.GroupState?
    let selectionSongCount: Int?

    init(
        node: LibraryFolderNode,
        selectionState: SongSelectionModel.GroupState?,
        selectionSongCount: Int? = nil
    ) {
        self.node = node
        self.selectionState = selectionState
        self.selectionSongCount = selectionSongCount
    }

    var body: some View {
        HStack(spacing: 10) {
            if let selectionState {
                Image(systemName: selectionIcon(for: selectionState))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(selectionState == .none ? Color.secondary : theme.uiAccentColor)
                    .frame(width: 28, height: 44)
                    .accessibilityHidden(true)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(folderTint.opacity(0.12))

                Image(systemName: LibraryFolderNodePresentation.icon(for: node.kind))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(folderTint)
                    .accessibilityHidden(true)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LibraryFolderNodePresentation.title(for: node))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(verbatim: LibraryFolderNodePresentation.songCount(node.descendantSongCount))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if selectionState == nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background {
            if let selectionState, selectionState != .none {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.uiAccentColor.opacity(selectionState == .all ? 0.11 : 0.07))
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: LibraryFolderNodePresentation.title(for: node)))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityIdentifier(
            "libraryFolderNode.\(node.kind.rawValue).\(LibraryFolderNodePresentation.accessibilityToken(for: node.id))"
        )
    }

    private func selectionIcon(for state: SongSelectionModel.GroupState) -> String {
        switch state {
        case .none: return "circle"
        case .partial: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }

    private var folderTint: Color {
        node.kind == .other ? Color.secondary : theme.uiAccentColor
    }

    private var accessibilityValue: String {
        let songCount = LibraryFolderNodePresentation.songCount(
            selectionSongCount ?? node.descendantSongCount
        )
        guard let selectionState else { return songCount }
        let state: String
        switch selectionState {
        case .none:
            state = String(localized: "library_folder_selection_none")
        case .partial:
            state = String(localized: "library_folder_selection_partial")
        case .all:
            state = String(localized: "library_folder_selection_all")
        }
        return "\(state), \(songCount)"
    }
}

private struct LibraryFolderNodeView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:「⋯」并进系统溢出菜单。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    // Resolved here, in the page's own view graph, because the folder menu it
    // feeds is rendered by a navigation-bar item host that cannot rely on the
    // environment reaching it. See `FolderPlaylistMenuButton`.
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(MetadataBackfillService.self) private var backfill
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    #endif

    let nodeID: LibraryFolderNodeID
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder
    var initialLocation: SongLibraryLocationRequest? = nil
    @State private var songLocation = SongListLocation()
    @State private var folderLocationDestination: FolderSongLocationRequest?
    @State private var consumedInitialLocationID: UUID?
    @AppStorage(LibraryFolderSongOrderPreference.followsListSortKey)
    private var followsListSort = false
    #if os(iOS)
    @AppStorage(SongListAppearance.storageKey)
    private var storedSongListAppearance = SongListAppearance.list.rawValue
    #endif
    @State private var maintenance = LibraryFolderMaintenanceModel()

    private var maintenanceActions: LibraryFolderMaintenanceActions? {
        LibraryFolderMaintenanceActions.make(
            nodeID: nodeID,
            index: folderCache.index,
            songIDs: actionSongIDs,
            model: maintenance,
            scanService: scanService,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore,
            library: library,
            scraperService: scraperService,
            backfill: backfill
        )
    }

    var body: some View {
        #if DEBUG && os(iOS)
        let _ = PlayerUIUpdateDiagnostics.body("folder")
        let _ = SongListRenderDiagnostics.didBuildFolder?(nodeID)
        #endif
        content
            .songLocationReader(songLocation, revision: FolderSongLocationRevision(
                nodeID: nodeID,
                indexRevision: folderCache.revision,
                songOrderRevision: listCache.rowOrderRevision
            ))
            .onAppear {
                if let initialLocation, consumedInitialLocationID != initialLocation.id {
                    consumedInitialLocationID = initialLocation.id
                    songLocation.locate(initialLocation.songID)
                }
            }
            .onDisappear { songLocation.cancel() }
            .navigationTitle(Text(verbatim: navigationTitle))
            #if os(iOS)
            .modifier(SongListAppearancePreference())
            .navigationBarTitleDisplayMode(.inline)
            .minimalNavigationDetail()
            .toolbar { iosToolbar }
            .navigationDestination(item: $folderLocationDestination) { destination in
                LibraryFolderNodeView(
                    nodeID: destination.nodeID,
                    folderCache: folderCache,
                    listCache: listCache,
                    selection: selection,
                    sortOrder: $sortOrder,
                    initialLocation: destination.song
                )
            }
            .librarySearchContext {
                guard let index = folderCache.index, let node = index.node(withID: nodeID) else { return nil }
                return LibrarySearchScope.folder(
                    node: node,
                    index: index,
                    title: LibraryFolderNodePresentation.title
                )
            }
            #endif
            .songBatchActions(
                selection: selection,
                context: nodeID.sourceID == AppleMusicLibraryIdentity.sourceID
                    ? .readOnly
                    : .library,
                orderedIDs: { actionSongIDs },
                resolve: { library.unobservedVisibleSong(id: $0) }
            )
            .onChange(of: folderCache.revision) { _, _ in
                pruneSelection()
            }
            .onChange(of: listCache.rowOrderRevision) { _, _ in
                pruneSelection()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let node = folderCache.node(withID: nodeID) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    #if os(macOS)
                    macFolderHeader(node)
                    #endif

                    LibraryFolderMaintenanceStatus(sourceID: nodeID.sourceID, model: maintenance)

                    let children = folderCache.children(of: nodeID)
                    if !children.isEmpty {
                        sectionHeader("library_browse_folder")
                        ForEach(children) { child in
                            LibraryFolderNodeBranch(
                                nodeID: child.id,
                                depth: 0,
                                folderCache: folderCache,
                                listCache: listCache,
                                selection: selection,
                                sortOrder: $sortOrder,
                                onOpenFolder: nil
                            )
                            .id(child.id)
                        }
                    }

                    if !visibleSongIDs.isEmpty {
                        sectionHeader("tab_songs")
                        if songListAppearance == .list {
                            folderSongRows
                        } else {
                            // 外层还带着子目录与标题，时间线与封面单独排成一个栈；每首歌仍带自己的定位身份。
                            // 外层左右各留了 8 点：时间线再补一点凑成与歌曲页相同的留白，封面抵掉它贴到屏幕边。
                            SongTimelineStack(
                                appearance: songListAppearance,
                                horizontalInset: songListAppearance == .artwork
                                    ? -8
                                    : SongTimelineRowMetrics.timelineHorizontalInset - 8
                            ) {
                                folderSongRows
                            }
                        }
                    }

                    if children.isEmpty && visibleSongIDs.isEmpty {
                        ContentUnavailableView(
                            "no_songs",
                            systemImage: "folder",
                            description: Text("no_songs_desc")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 8)
                #if os(iOS)
                .padding(.bottom, appNavigationMode == .minimal ? 16 : 112)
                #else
                .padding(.bottom, 112)
                #endif
            }
            .pmExtendsUnderVerticalBar()
            .background(LibraryFolderNodePresentation.background.ignoresSafeArea())
        } else {
            ContentUnavailableView(
                "no_songs",
                systemImage: "folder.badge.questionmark",
                description: Text("no_songs_desc")
            )
        }
    }

    private var folderSongRows: some View {
        ForEach(Array(visibleSongIDs.enumerated()), id: \.element) { index, songID in
            LibraryFolderSongRow(
                songID: songID,
                ordinal: index + 1,
                totalCount: visibleSongIDs.count,
                orderedIDs: { visibleSongIDs },
                listCache: listCache,
                selection: selection,
                onPlay: playSong
            )
            .id(SongLocationScrollID(songID: songID))
        }
    }

    /// 这一页自己挂着外观偏好，读环境拿不到，直接读存储；Mac 没有这个选项。
    private var songListAppearance: SongListAppearance {
        #if os(iOS)
        SongListAppearance.resolved(storedSongListAppearance)
        #else
        .list
        #endif
    }

    private var navigationTitle: String {
        guard let node = folderCache.node(withID: nodeID) else {
            return String(localized: "library_browse_folder")
        }
        return LibraryFolderNodePresentation.title(for: node)
    }

    private var visibleSongIDs: [String] {
        folderCache.orderedSongIDs(
            in: nodeID,
            scope: .visible,
            listCache: listCache
        )
    }

    private var actionSongIDs: [String] {
        folderCache.orderedSongIDs(
            in: nodeID,
            scope: .action,
            listCache: listCache
        )
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.headline)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private func macFolderHeader(_ node: LibraryFolderNode) -> some View {
        HStack(spacing: 12) {
            Label(
                LibraryFolderNodePresentation.title(for: node),
                systemImage: LibraryFolderNodePresentation.icon(for: node.kind)
            )
            .font(.title2.weight(.semibold))

            Spacer()

            // 目录里的一层: 和上面工具条同一档 26 高的自绘键(`MacControlTier.toolbar`),
            // 原来是系统的描边按钮和无边框菜单。
            Button {
                playAllSongsInFolder()
            } label: {
                Label("play_all", systemImage: "play.fill")
                    .macControlChrome(.prominent)
            }
            .buttonStyle(.plain)
            .disabled(node.descendantSongCount == 0)

            Menu {
                Picker("sort_by", selection: macSortBinding) {
                    Text("sort_track_order").tag(SongListView.SongSortOrder?.none)
                    ForEach(SongListView.SongSortOrder.allCases, id: \.self) { order in
                        Text(verbatim: order.label).tag(Optional(order))
                    }
                }
            } label: {
                MacControlMenuLabel(
                    verbatim: macSortBinding.wrappedValue?.label ?? String(localized: "sort_track_order"),
                    systemImage: "arrow.up.arrow.down"
                )
            }
            .macControlMenuStyle()
            .disabled(selection.isActive)
            .help(Text("sort_by"))
            .accessibilityLabel(Text("sort_by"))

            if let maintenanceActions {
                Menu {
                    LibraryFolderMaintenanceMenuItems(actions: maintenanceActions)
                } label: {
                    Image(systemName: "ellipsis")
                        .macControlChrome(iconOnly: true)
                }
                .macControlMenuStyle()
                .disabled(selection.isActive)
                .help(Text("a11y_more_actions"))
                .accessibilityLabel(Text("a11y_more_actions"))
            }
        }
        .macControlTier(.toolbar)
        .padding(12)
    }

    /// nil = 曲目顺序; 选其它排序就跟随歌曲列表。
    private var macSortBinding: Binding<SongListView.SongSortOrder?> {
        Binding(
            get: { followsListSort ? sortOrder : nil },
            set: { newOrder in
                guard let newOrder else {
                    followsListSort = false
                    return
                }
                followsListSort = true
                sortOrder = newOrder
            }
        )
    }
    #endif

    #if os(iOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            LocateCurrentSongButton(
                isEditing: selection.isActive,
                titled: verticalBarEdge != nil,
                contains: { listCache.contains(songID: $0) }
            ) { songID, _ in
                guard let target = folderCache.index?.nodeID(containingSongID: songID) else { return }
                if target == nodeID {
                    songLocation.locate(songID)
                } else {
                    folderLocationDestination = FolderSongLocationRequest(
                        nodeID: target, song: SongLibraryLocationRequest(songID: songID)
                    )
                }
            }
        }
        ToolbarItem(placement: .principal) {
            LibraryFolderToolbarPrincipal(
                selection: selection,
                title: navigationTitle
            )
        }
        if verticalBarEdge != nil {
            verticalBarToolbar
        } else {
            standardTrailingToolbar
        }
    }

    /// 系统竖栏(iPhone Duo):「播放全部」优先留在栏里;「⋯」的内容(置顶、存为歌单、多选、排序)
    /// 并进系统溢出菜单。
    @ToolbarContentBuilder
    private var verticalBarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            LibraryFolderPlayAllToolbarItem(
                selection: selection,
                isEnabled: !actionSongIDs.isEmpty,
                titled: true,
                action: playAllSongsInFolder
            )
            SongSelectionCancelToolbarItem(selection: selection, titled: true)
        }
        .pmHighVisibilityPriority()
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu {
                LibraryFolderNormalToolbarMenu(
                    selection: selection,
                    sortOrder: $sortOrder,
                    nodeID: nodeID,
                    index: folderCache.index,
                    library: library,
                    source: sourcesStore.source(id: nodeID.sourceID),
                    maintenance: maintenanceActions,
                    asOverflowItems: true
                )
                if selection.isActive {
                    SongSelectionOptionsMenu(
                        selection: selection,
                        orderedIDs: { actionSongIDs },
                        asOverflowItems: true
                    )
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var standardTrailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            LibraryFolderPlayAllToolbarItem(
                selection: selection,
                isEnabled: !actionSongIDs.isEmpty,
                action: playAllSongsInFolder
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            LibraryFolderNormalToolbarMenu(
                selection: selection,
                sortOrder: $sortOrder,
                nodeID: nodeID,
                index: folderCache.index,
                library: library,
                source: sourcesStore.source(id: nodeID.sourceID),
                maintenance: maintenanceActions
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            SongSelectionOptionsToolbarItem(
                selection: selection,
                orderedIDs: { actionSongIDs }
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            SongSelectionCancelToolbarItem(selection: selection)
        }
    }
    #endif

    private func playAllSongsInFolder() {
        let ids = actionSongIDs
        guard let first = ids.lazy.compactMap({ library.unobservedVisibleSong(id: $0) }).first else { return }
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(queueIDs: ids) }
    }

    private func playSong(_ song: Song) {
        let ids = visibleSongIDs
        guard let index = ids.firstIndex(of: song.id) else { return }
        #if DEBUG && os(iOS)
        PlayerUIUpdateDiagnostics.begin("play")
        #endif
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queueIDs: ids, startingAt: index) }
    }

    private func pruneSelection() {
        guard selection.isActive, !selection.isEmpty else { return }
        selection.prune(to: Set(actionSongIDs))
    }
}

private struct LibraryFolderSongRow: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.songListAppearance) private var appearance

    let songID: String
    let ordinal: Int
    let totalCount: Int
    let orderedIDs: () -> [String]
    let listCache: SongListCache
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    @ViewBuilder
    var body: some View {
        if let model = listCache.rowModel(
            id: songID,
            song: library.unobservedVisibleSong(id: songID)
        ) {
            #if os(iOS)
            // 时间线与封面的留白、行距由外面的 `SongTimelineStack` 与固定的槽位高度给。
            IOSSongListRow(model: model, ordinal: ordinal, totalCount: totalCount, selection: selection, onPlay: onPlay)
                .padding(.horizontal, appearance == .list ? 8 : 0)
                .padding(.vertical, appearance == .list ? 5 : 0)
            #else
            IOSSongListRow(model: model, ordinal: ordinal, totalCount: totalCount, selection: selection, onPlay: onPlay)
                .songSelectable(
                    songID: songID,
                    selection: selection,
                    orderedIDs: orderedIDs,
                    defaultAction: { onPlay(model.song) }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            #endif

            if appearance == .list {
                Divider()
                    .padding(.leading, 72)
            }
        }
    }
}

/// The view owns the observed position for its lifetime, including while SwiftUI prefetches it.
private struct ObservedSongListPosition<Content: View>: View {
    let model: SongListPositionModel
    @ViewBuilder let content: (SongListRowIdentity) -> Content

    var body: some View {
        if let row = model.row { content(row) }
    }
}

private struct IOSSongListPositionRow: View {
    @Environment(MusicLibrary.self) private var library

    let position: Int
    let cache: SongListCache
    let locatedSongID: String?
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    @ViewBuilder
    var body: some View {
        ObservedSongListPosition(model: cache.positionModel(at: position)) { row in
            if let model = cache.rowModel(
                   id: row.id,
                   song: library.unobservedVisibleSong(id: row.id)
               ) {
                #if os(iOS)
                IOSSongListRow(
                    model: model,
                    ordinal: position + 1,
                    totalCount: cache.positionCount,
                    selection: selection,
                    onPlay: onPlay,
                    isLocated: row.id == locatedSongID
                )
                    // The structural List identity stays bound to `position`,
                    // while VoiceOver tracks the song currently occupying it.
                    .accessibilityIdentifier("songRow.\(row.id)")
                #else
                IOSSongListRow(model: model, ordinal: position + 1, totalCount: cache.positionCount, selection: selection, onPlay: onPlay)
                    .songSelectable(
                        songID: row.id,
                        selection: selection,
                        orderedIDs: { cache.orderedSongIDs },
                        defaultAction: { onPlay(model.song) }
                    )
                    // The structural identity stays bound to `position`,
                    // while VoiceOver tracks the song currently occupying it.
                    .accessibilityIdentifier("songRow.\(row.id)")
                #endif
            }
        }
    }
}

/// Observing selection mode in the parent `SongListView` invalidates the
/// complete large-list description. This zero-size child owns the one
/// selection lifecycle side effect instead.
private struct SongSelectionActivationObserver: View {
    let selection: SongSelectionModel
    let onActivate: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: selection.isActive) { _, isActive in
                if isActive { onActivate() }
            }
    }
}

// MARK: - Catalog-backed rows (P2a)

/// 目录列表里定位查行号的身份:哪首、对哪一版行号。
private struct SongListCatalogLocateKey: Equatable {
    let songID: String?
    let rowRevision: Int
}

private struct SongListCatalogLocatedRow: Equatable {
    let key: SongListCatalogLocateKey
    let position: Int
}

/// 多选开始 / 结束时让目录列表取 / 放这份列表的 id。零尺寸子视图,父视图不观察多选状态。
private struct SongListCatalogSelectionObserver: View {
    let selection: SongSelectionModel
    let catalogList: SongListCatalogList

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: selection.isActive, initial: true) { _, isActive in
                catalogList.setWantsSelectionIDs(isActive)
            }
    }
}

#if os(iOS)
/// `IOSSongListContainer` 的目录版:行数、分节来自目录,行按位置从当前那一份按页取,
/// 还没取到的位置画占位行。一个位置一个子视图、一个滚动目标,字母索引与定位按位置跳。
private struct IOSCatalogSongListContainer: View, @MainActor Equatable {
    let catalog: SongListCatalogList
    let rowRevision: Int
    let sectionIndexEntries: [SongListSectionIndexEntry]
    let locatedSongID: String?
    let locationRequestID: UUID?
    @Environment(\.songListLocation) private var location
    @Environment(\.songListAppearance) private var appearance
    let selection: SongSelectionModel
    let showsListeningIntents: Bool
    let onPlay: (Song) -> Void

    @State private var indexScrollRequest: IOSSongIndexScrollRequest?
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var scrollAnchor: UnitPoint = .top
    @State private var indexTracker = LibraryIndexRailTracker()
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge

    private var sectionIndexTrailingInset: CGFloat {
        verticalBarEdge == .trailing ? 10 : 2
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.catalog === rhs.catalog
            && lhs.rowRevision == rhs.rowRevision
            && lhs.sectionIndexEntries == rhs.sectionIndexEntries
            && lhs.locatedSongID == rhs.locatedSongID
            && lhs.locationRequestID == rhs.locationRequestID
            && lhs.selection === rhs.selection
            && lhs.showsListeningIntents == rhs.showsListeningIntents
    }

    var body: some View {
        let rowCount = catalog.count
        let railModel = LibraryIndexRailModel(songEntries: sectionIndexEntries, rowCount: rowCount)
        let showsIndex = showsSectionIndex(rowCount: rowCount)
        return ZStack(alignment: .trailing) {
            ScrollView {
                if showsListeningIntents {
                    StartListeningShelf(horizontalInset: 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
                positionStack(rowCount: rowCount, showsIndex: showsIndex)
            }
            .scrollPosition($scrollPosition, anchor: scrollAnchor)
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.5) { positions in
                guard let top = positions.min() else { return }
                indexTracker.lastTopPosition = top
                guard showsIndex else { return }
                indexTracker.update(railModel.label(containing: top))
            }
            .pmExtendsUnderVerticalBar()
            .background(Color(UIColor.systemBackground))
            .songRowColumnsContainer()

            if showsIndex {
                LibraryIndexRail(
                    entries: railModel.entries,
                    tracker: indexTracker,
                    hitWidth: 48,
                    countText: { LibraryCountText.formattedSongs($0) },
                    preview: { _ in EmptyView() }
                ) { entry in
                    guard (0..<catalog.count).contains(entry.target) else { return }
                    indexScrollRequest = IOSSongIndexScrollRequest(
                        rowOffset: entry.target,
                        rowOrderRevision: rowRevision
                    )
                }
                .accessibilityIdentifier("songList.alphabetIndex")
                .padding(.trailing, sectionIndexTrailingInset)
                .padding(.top, showsListeningIntents ? 48 : 0)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .task(id: indexScrollRequest) {
            guard let request = indexScrollRequest else { return }
            scrollAnchor = .top
            await Task.yield()
            guard !Task.isCancelled,
                  request.rowOrderRevision == rowRevision,
                  (0..<catalog.count).contains(request.rowOffset) else {
                return
            }
            scrollPosition.scrollTo(id: request.rowOffset, anchor: .top)
        }
        .task(id: SongLocationScrollTrigger(
            requestID: locationRequestID,
            songID: locatedSongID,
            rowOrderRevision: rowRevision
        )) {
            // 目录列表里按行号查那首在第几行(主线程外取行号,再在整列行号里找)。
            guard location?.needsScroll != false, let locatedSongID,
                  let rowOffset = await catalog.position(of: locatedSongID) else { return }
            scrollAnchor = .center
            await Task.yield()
            guard !Task.isCancelled,
                  self.locatedSongID == locatedSongID,
                  rowRevision == catalog.rowRevision else { return }
            scrollPosition.scrollTo(id: rowOffset, anchor: .center)
        }
        .onChange(of: rowRevision) { _, _ in
            indexScrollRequest = nil
            indexTracker.update(indexTracker.lastTopPosition.flatMap(railModel.label(containing:)))
        }
        .pmAnimation(.control, value: showsIndex)
    }

    @ViewBuilder
    private func positionStack(rowCount: Int, showsIndex: Bool) -> some View {
        if appearance == .list {
            LazyVStack(spacing: 0) {
                positionSlots(rowCount: rowCount, showsIndex: showsIndex)
            }
            .scrollTargetLayout()
        } else {
            SongTimelineStack(appearance: appearance) {
                positionSlots(rowCount: rowCount, showsIndex: showsIndex)
            }
        }
    }

    private func positionSlots(rowCount: Int, showsIndex: Bool) -> some View {
        ForEach(0..<rowCount, id: \.self) { position in
            IOSCatalogSongListPositionSlot(
                position: position,
                isLast: position == rowCount - 1,
                trailingPadding: showsIndex ? 40 + sectionIndexTrailingInset : 16,
                catalog: catalog,
                locatedSongID: locatedSongID,
                selection: selection,
                onPlay: onPlay
            )
        }
    }

    /// 同 `IOSSongListContainer.showsSectionIndex`。
    private func showsSectionIndex(rowCount: Int) -> Bool {
        appearance == .list
            && !selection.isActive
            && rowCount >= 24
            && sectionIndexEntries.lazy.filter(\.isAvailable).count > 1
    }
}

private struct IOSCatalogSongListPositionSlot: View {
    let position: Int
    let isLast: Bool
    let trailingPadding: CGFloat
    let catalog: SongListCatalogList
    let locatedSongID: String?
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void
    @Environment(\.songRowStyle) private var rowStyle
    @Environment(\.songListAppearance) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            IOSCatalogSongListPositionRow(
                position: position,
                catalog: catalog,
                locatedSongID: locatedSongID,
                selection: selection,
                onPlay: onPlay
            )
            .padding(.leading, appearance == .list ? 16 : 0)
            .padding(.trailing, appearance == .list ? trailingPadding : 0)
            .padding(.vertical, appearance == .list ? 4 : 0)

            if appearance == .list {
                Divider()
                    .padding(.leading, rowStyle.separatorLeadingInset)
                    .opacity(isLast ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct IOSCatalogSongListPositionRow: View {
    let position: Int
    let catalog: SongListCatalogList
    let locatedSongID: String?
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    @ViewBuilder
    var body: some View {
        if let song = catalog.song(at: position) {
            IOSSongListRow(
                model: catalog.rowModel(for: song),
                ordinal: position + 1,
                totalCount: catalog.count,
                selection: selection,
                onPlay: onPlay,
                isLocated: song.id == locatedSongID
            )
            // 结构身份绑在位置上,VoiceOver 跟着这个位置上的歌。
            .accessibilityIdentifier("songRow.\(song.id)")
        } else {
            SongListCatalogPlaceholderRow()
        }
    }
}

/// 那一页还没从目录取到时的占位行:与歌曲行同样的封面格与两行字高,取到后原地换成歌曲行。
private struct SongListCatalogPlaceholderRow: View {
    @Environment(\.songRowStyle) private var rowStyle
    @Environment(\.songListAppearance) private var appearance
    @ScaledMetric(relativeTo: .subheadline) private var timelineCardHeight = SongTimelineRowMetrics.timelineCardHeight
    @ScaledMetric(relativeTo: .subheadline) private var artworkCapsuleHeight = SongTimelineRowMetrics.artworkCapsuleHeight

    var body: some View {
        Group {
            switch appearance {
            case .list:
                HStack(spacing: rowStyle.artworkSpacing) {
                    RoundedRectangle(cornerRadius: rowStyle.artworkCornerRadius)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: rowStyle.artworkSize, height: rowStyle.artworkSize)
                    VStack(alignment: .leading, spacing: rowStyle.textSpacing) {
                        Text(verbatim: "Song title placeholder")
                            .font(rowStyle.titleFont)
                        Text(verbatim: "Artist placeholder")
                            .font(rowStyle.subtitleFont)
                    }
                    .redacted(reason: .placeholder)
                    Spacer(minLength: 0)
                }
            case .timeline:
                Color.clear.frame(height: timelineCardHeight)
            case .artwork:
                Color.clear.frame(height: artworkCapsuleHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
#endif

private struct SongListToolbarPrincipal: View {
    let selection: SongSelectionModel
    let progress: SongListSortProgressModel

    @ViewBuilder
    var body: some View {
        if selection.isActive {
            SongSelectionToolbarTitle(selection: selection)
        } else {
            SongListSortProgressIndicator(progress: progress)
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

/// 只剩 macOS 列表头的排序按钮在用: 那里的菜单跟着一排工具条控件, 六个维度平铺
/// 一层反而比子菜单快。iOS 的「更多」菜单改用 `SongSortSubmenu`。
#if os(macOS)
private struct SongSortMenuOptions: View {
    @Binding var sortOrder: SongListView.SongSortOrder
    /// 文件夹模式传入: 多一个「曲目顺序」, 选其它维度才跟随歌曲列表。
    var followsListSort: Binding<Bool>? = nil

    private var usesListSort: Bool { followsListSort?.wrappedValue ?? true }

    var body: some View {
        if let followsListSort {
            Button {
                followsListSort.wrappedValue = false
            } label: {
                if usesListSort {
                    Text("sort_track_order")
                } else {
                    Label("sort_track_order", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
            }
            Divider()
        }
        ForEach(LibrarySongSortCriterion.menuCases, id: \.self) { criterion in
            Button {
                if let followsListSort, !followsListSort.wrappedValue {
                    // 从曲目顺序切回来时只换维度, 不把当前维度调头。
                    followsListSort.wrappedValue = true
                    if sortOrder.criterion == criterion { return }
                }
                sortOrder = sortOrder.selecting(criterion)
            } label: {
                if usesListSort, sortOrder.criterion == criterion {
                    // 当前排序与升降序只靠这个图标表达；macOS 27 起菜单默认隐藏图标。
                    Label(criterion.label, systemImage: sortOrder.directionIcon)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(verbatim: criterion.label)
                }
            }
            .accessibilityValue(
                usesListSort && sortOrder.criterion == criterion
                    ? Text(verbatim: sortOrder.directionLabel)
                    : Text(verbatim: "")
            )
        }
    }
}
#endif

/// 排序原本要占「更多」菜单的六行, 收进子菜单后只剩一行, 菜单主层留给真正的动作。
/// 里面把「按什么排」和「升降序」拆成两段单选 —— 原本这两件事挤在同一组按钮里,
/// 靠「再点一次当前项」翻转, 看不出来也点不准。
/// 工具栏条目跑在自己的视图图里, 所以只收 Binding, 不读环境。
private struct SongSortSubmenu: View {
    @Binding var sortOrder: SongListView.SongSortOrder
    /// 文件夹页传入: 维度列表最前面多一个「曲目顺序」, 选它就不跟随歌曲列表的排序。
    var followsListSort: Binding<Bool>? = nil

    var body: some View {
        Menu {
            Section {
                Picker("sort_by", selection: criterionBinding) {
                    if followsListSort != nil {
                        Text("sort_track_order")
                            .tag(LibrarySongSortCriterion?.none)
                    }
                    ForEach(LibrarySongSortCriterion.menuCases, id: \.self) { criterion in
                        Text(verbatim: criterion.label)
                            .tag(Optional(criterion))
                    }
                }
                .pickerStyle(.inline)
            }

            // 曲目顺序固定从第一首读起, 没有升降序可选。
            if usesListSort {
                Section {
                    Picker("smart_sort_direction", selection: ascendingBinding) {
                        Label("smart_sort_ascending", systemImage: "arrow.up")
                            .tag(true)
                        Label("smart_sort_descending", systemImage: "arrow.down")
                            .tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            Label("sort_by", systemImage: "arrow.up.arrow.down")
        }
    }

    private var usesListSort: Bool { followsListSort?.wrappedValue ?? true }

    /// `selecting` 对同一个维度是「调头」语义, 所以维度没变时一次都不能调用它,
    /// 否则点回当前选中项就会莫名其妙地翻转升降序。
    private var criterionBinding: Binding<LibrarySongSortCriterion?> {
        Binding(
            get: { usesListSort ? sortOrder.criterion : nil },
            set: { newCriterion in
                guard let newCriterion else {
                    followsListSort?.wrappedValue = false
                    return
                }
                followsListSort?.wrappedValue = true
                guard newCriterion != sortOrder.criterion else { return }
                sortOrder = sortOrder.selecting(newCriterion)
            }
        )
    }

    /// 升降序借的就是同一条调头语义: 对当前维度再选一次即可翻转, 不必新增接口,
    /// 持久化的值域也还是那个枚举。
    private var ascendingBinding: Binding<Bool> {
        Binding(
            get: { sortOrder.isAscending },
            set: { newValue in
                guard newValue != sortOrder.isAscending else { return }
                sortOrder = sortOrder.selecting(sortOrder.criterion)
            }
        )
    }
}

/// 工具栏条目跑在自己的视图图里, 所以可用状态和动作都按值传进来, 不读环境。
private struct SongListShuffleToolbarButton: View {
    let selection: SongSelectionModel
    let isEnabled: Bool
    /// 系统竖栏里带上标题(收进溢出菜单时要用),其它时候仍是原来的纯图标。
    var titled = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if !selection.isActive {
            Button(action: action) {
                PMToolbarItemLabel("shuffle_all", systemImage: "shuffle", titled: titled)
            }
            .disabled(!isEnabled)
            .accessibilityLabel(Text("shuffle_all"))
            .accessibilityIdentifier("songList.shuffleAll")
        }
    }
}

private struct SongListBrowseModeToolbarButton: View {
    let selection: SongSelectionModel
    @Binding var browseMode: LibrarySongBrowseMode
    /// 目录被挡住时眼前其实是平铺：键换成画灰的「目录」，仍可点，点了说明原因。
    var folderBlocker: LibraryFolderBrowseBlocker? = nil
    /// 说明框挂在页面上（`folderBrowseBlockerAlert`）：同一件事也可能从「⋯」系统菜单里点，菜单项上挂不住。
    var explainBlocker: (LibraryFolderBrowseBlocker) -> Void = { _ in }
    /// 系统竖栏里带上标题,其它时候仍是原来的纯图标。
    var titled = false

    /// 点下去去目录：正在平铺，或目录被挡住。
    private var offersFolder: Bool {
        browseMode != .folder || folderBlocker != nil
    }

    private var label: PMToolbarItemLabel {
        PMToolbarItemLabel(
            LocalizedStringKey(offersFolder ? "library_browse_folder" : "library_browse_flat"),
            systemImage: offersFolder ? "folder" : "list.bullet",
            titled: titled
        )
    }

    var body: some View {
        if !selection.isActive {
            Button {
                if let folderBlocker {
                    explainBlocker(folderBlocker)
                } else {
                    browseMode = browseMode == .folder ? .flat : .folder
                }
            } label: {
                // 只在挡住时换色，平时不碰工具栏自己的着色(同 SourcesView 的读标签速度键)。
                if folderBlocker == nil {
                    label
                } else {
                    label.foregroundStyle(Color.secondary)
                }
            }
            .accessibilityLabel(Text(LocalizedStringKey(
                offersFolder ? "library_browse_folder" : "library_browse_flat"
            )))
            .accessibilityValue(Text(LocalizedStringKey(
                offersFolder ? "library_browse_flat" : "library_browse_folder"
            )))
            .accessibilityHint(folderBlocker.map { Text($0.titleKey) } ?? Text(verbatim: ""))
            .accessibilityIdentifier("libraryBrowseMode.toggle")
        }
    }
}

/// 歌曲页顶栏、页头四颗键收进「⋯」系统菜单时，菜单顶上那一排里的随机播放与目录 / 平铺（顶栏还会在前面
/// 加上定位）。文字用短的那条。目录被挡住时仍可点，说明框由页面挂在菜单外面。
private struct SongListMenuQuickActions: View {
    let canShuffle: Bool
    let shuffle: () -> Void
    @Binding var browseMode: LibrarySongBrowseMode
    let folderBlocker: LibraryFolderBrowseBlocker?
    let explainBlocker: (LibraryFolderBrowseBlocker) -> Void

    /// 点下去去目录：正在平铺，或目录被挡住。
    private var offersFolder: Bool {
        browseMode != .folder || folderBlocker != nil
    }

    var body: some View {
        PMMenuQuickActionButton(shortKey: "shuffle", fullKey: "shuffle_all", systemImage: "shuffle", action: shuffle)
            .disabled(!canShuffle)
            .accessibilityIdentifier("songList.shuffleAll")
        PMMenuQuickActionButton(
            shortKey: offersFolder ? "library_browse_folder" : "library_browse_flat",
            fullKey: offersFolder ? "library_browse_folder" : "library_browse_flat",
            systemImage: offersFolder ? "folder" : "list.bullet"
        ) {
            if let folderBlocker {
                explainBlocker(folderBlocker)
            } else {
                browseMode = browseMode == .folder ? .flat : .folder
            }
        }
        .accessibilityValue(Text(LocalizedStringKey(offersFolder ? "library_browse_flat" : "library_browse_folder")))
        .accessibilityHint(folderBlocker.map { Text($0.titleKey) } ?? Text(verbatim: ""))
        .accessibilityIdentifier("libraryBrowseMode.toggle")
    }
}

/// 目录浏览只在「全部」而且没在页内查找时出现；挡住它的是哪一个，说明与一键解决就写哪一个。
private enum LibraryFolderBrowseBlocker: Hashable {
    case downloadedFilter
    case search

    var titleKey: LocalizedStringKey {
        switch self {
        case .downloadedFilter: "library_browse_folder_blocked_downloaded_title"
        case .search: "library_browse_folder_blocked_search_title"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .downloadedFilter: "library_browse_folder_blocked_downloaded_message"
        case .search: "library_browse_folder_blocked_search_message"
        }
    }

    var actionKey: LocalizedStringKey {
        switch self {
        case .downloadedFilter: "library_browse_folder_blocked_downloaded_action"
        case .search: "library_browse_folder_blocked_search_action"
        }
    }
}

private extension View {
    /// 标题、说明与按钮跟着 `blocker` 走；收起时 `blocker` 不清空，免得淡出那一下标题变空。
    func folderBrowseBlockerAlert(
        isPresented: Binding<Bool>,
        blocker: LibraryFolderBrowseBlocker,
        resolve: @escaping () -> Void
    ) -> some View {
        alert(blocker.titleKey, isPresented: isPresented) {
            Button(blocker.actionKey, action: resolve)
            Button("cancel", role: .cancel) {}
        } message: {
            Text(blocker.messageKey)
        }
    }
}

/// 歌曲页「⋯」系统菜单里原来的内容：排序、列表样式、只看已下载，多选与添加首页目录。
/// 顶栏、页头四颗键收起时 `PMToolbarMoreMenu` 在它上面加一排快捷操作。
private struct SongListMoreMenuItems: View {
    let selection: SongSelectionModel
    let sortOrder: Binding<SongListView.SongSortOrder>
    @Binding var filter: SongListView.SongFilter
    var manageHomeFolders: (() -> Void)?
    /// 文件夹根目录传入: 文件夹里的歌默认按曲目顺序, 排序菜单要能看出这一点,
    /// 选别的维度时也要让文件夹跟随, 否则在根目录选排序没有任何效果。
    var folderFollowsListSort: Binding<Bool>? = nil

    var body: some View {
        Section {
            SongSortSubmenu(sortOrder: sortOrder, followsListSort: folderFollowsListSort)

            #if os(iOS)
            SongListAppearancePicker()
            #endif

            // 筛选：显式离线下载 / 离线可用（含已缓存与本机）。
            Toggle(isOn: downloadedBinding) {
                Label("filter_downloaded", systemImage: "arrow.down.circle")
            }
            Toggle(isOn: offlineAvailableBinding) {
                Label("filter_offline_available", systemImage: "wifi.slash")
            }
        }

        Section {
            Button {
                selection.activate()
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }
            if let manageHomeFolders {
                Button(HomeDiscoveryText.string("add_folder"), systemImage: "pin", action: manageHomeFolders)
                    .accessibilityIdentifier("library.manageHomeFolders")
            }
        }
    }

    private var downloadedBinding: Binding<Bool> {
        Binding(
            get: { filter == .downloaded },
            set: { filter = $0 ? .downloaded : .all }
        )
    }

    private var offlineAvailableBinding: Binding<Bool> {
        Binding(
            get: { filter == .offlineAvailable },
            set: { filter = $0 ? .offlineAvailable : .all }
        )
    }
}

#if os(iOS)
/// 极简模式歌曲页的页头：左边「全部播放」带歌数，随机与版式；右边查找、排序与「⋯」。
/// 多选时换成「已选择几首」与全选、取消。选择态读在这个子视图里，
/// 进出多选不会让整张列表重算（同工具栏条目的做法）。
private struct SongListMinimalHeader: View {
    let selection: SongSelectionModel
    let progress: SongListSortProgressModel
    let countText: String
    let canPlay: Bool
    let canShuffle: Bool
    @Binding var browseMode: LibrarySongBrowseMode
    let folderBlocker: LibraryFolderBrowseBlocker?
    let explainFolderBlocker: (LibraryFolderBrowseBlocker) -> Void
    let sortOrder: Binding<SongListView.SongSortOrder>
    @Binding var filter: SongListView.SongFilter
    var manageHomeFolders: (() -> Void)?
    var folderFollowsListSort: Binding<Bool>?
    let orderedIDs: () -> [String]
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        if selection.isActive {
            SongSelectionMinimalHeader(selection: selection, orderedIDs: orderedIDs)
        } else {
            HStack(spacing: 4) {
                MinimalPlayAllButton(subtitle: countText, action: onPlay)
                    .disabled(!canPlay)
                Spacer(minLength: 4)
                SongListSortProgressIndicator(progress: progress)
                MinimalCollapsibleHeaderActions(otherActionCount: 4) {
                    SongListShuffleToolbarButton(selection: selection, isEnabled: canShuffle, action: onShuffle)
                    SongListBrowseModeToolbarButton(
                        selection: selection,
                        browseMode: $browseMode,
                        folderBlocker: folderBlocker,
                        explainBlocker: explainFolderBlocker
                    )
                    MinimalPageFindButton()
                    SongSortSubmenu(sortOrder: sortOrder, followsListSort: folderFollowsListSort)
                } primary: { collapsesActions in
                    // 收起时排序本来就在菜单里，顶上一排只放随机与目录。
                    PMToolbarMoreMenu(collapsesShortcuts: collapsesActions, identifier: "songList.more") {
                        SongListMenuQuickActions(
                            canShuffle: canShuffle,
                            shuffle: onShuffle,
                            browseMode: $browseMode,
                            folderBlocker: folderBlocker,
                            explainBlocker: explainFolderBlocker
                        )
                    } items: {
                        SongListMoreMenuItems(
                            selection: selection,
                            sortOrder: sortOrder,
                            filter: $filter,
                            manageHomeFolders: manageHomeFolders,
                            folderFollowsListSort: folderFollowsListSort
                        )
                    }
                }
            }
        }
    }
}
#endif

private struct LibraryFolderToolbarPrincipal: View {
    let selection: SongSelectionModel
    let title: String

    @ViewBuilder
    var body: some View {
        if selection.isActive {
            SongSelectionToolbarTitle(selection: selection)
        } else {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(1)
        }
    }
}

private struct LibraryFolderPlayAllToolbarItem: View {
    let selection: SongSelectionModel
    let isEnabled: Bool
    /// 系统竖栏里带上标题,其它时候仍是原来的纯图标。
    var titled = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if !selection.isActive {
            Button(action: action) {
                PMToolbarItemLabel("play_all", systemImage: "play.fill", titled: titled)
            }
            .disabled(!isEnabled)
            .accessibilityLabel(Text("play_all"))
            .accessibilityIdentifier("libraryFolder.playAll")
        }
    }
}

/// Toolbar items are hosted in their own view graph, so this menu takes every
/// model it needs as a value instead of reading the environment.
private struct LibraryFolderNormalToolbarMenu: View {
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder
    let nodeID: LibraryFolderNodeID
    let index: LibraryFolderIndex?
    let library: MusicLibrary
    let source: MusicSource?
    var maintenance: LibraryFolderMaintenanceActions?
    @AppStorage(LibraryFolderSongOrderPreference.followsListSortKey)
    private var followsListSort = false
    @AppStorage(HomeFolderPinStorage.key) private var pinsRawValue = ""

    /// 只给出菜单项,由系统竖栏的溢出菜单收进去,自己不再套一层「⋯」。
    var asOverflowItems = false

    /// 收藏的目录（也是首页「目录」区块摆的那几个）。没收藏过时首页自动推荐的不算。
    private var pins: [LibraryFolderNodeID] {
        FavoriteCollectionStore.collectedFolderIDs(in: pinsRawValue)
    }

    @ViewBuilder
    var body: some View {
        if !selection.isActive {
            if asOverflowItems {
                items
            } else {
                Menu {
                    items
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("a11y_more_actions"))
            }
        }
    }

    @ViewBuilder
    private var items: some View {
        // 三个常用动作交给系统排成顶部一行, 剩下的一行是排序。
        PMMenuQuickActions {
            let pinned = pins.contains(nodeID)
            PMMenuQuickActionButton(
                short: HomeDiscoveryText.string(pinned ? "unpin_folder_short" : "pin_folder_short"),
                full: HomeDiscoveryText.string(pinned ? "unpin_folder" : "pin_folder"),
                systemImage: pinned ? "heart.slash" : "heart"
            ) {
                PMHaptics.likeToggled(isLiked: !pinned)
                FavoriteCollectionStore.shared.setCollected(!pinned, .folder(nodeID), library: library)
            }
            .disabled(index?.node(withID: nodeID) == nil)
            .accessibilityIdentifier("libraryFolder.pinToHome")

            if let node = index?.node(withID: nodeID) {
                FolderPlaylistMenuButton(
                    node: node,
                    index: index,
                    library: library,
                    source: source,
                    isInQuickRow: true
                )
            }

            Button {
                selection.activate()
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }
        }

        SongSortSubmenu(sortOrder: $sortOrder, followsListSort: $followsListSort)

        #if os(iOS)
        SongListAppearancePicker()
        #endif

        if let maintenance {
            Section {
                LibraryFolderMaintenanceMenuItems(actions: maintenance)
            }
        }
    }
}

/// A row-level observation boundary. Metadata/backfill changes replace the
/// model for one song, and only this subtree re-evaluates; the parent List no
/// longer observes Song values or per-row source/backfill state.
private struct IOSSongListRow: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicLibrary.self) private var library
    @Environment(\.songListAppearance) private var appearance

    let model: SongListRowModel
    let ordinal: Int
    let totalCount: Int
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void
    var isLocated = false

    var body: some View {
        let song = model.song
        let membership = selection.isActive
            ? selection.membership(for: song.id)
            : nil
        let isSelected = membership?.isSelected == true
        Group {
            if let membership {
                switch appearance {
                case .list:
                    IOSSelectionSongRow(
                        song: song,
                        isPlaying: player.currentSong?.id == song.id,
                        ordinal: ordinal,
                        totalCount: totalCount,
                        membership: membership
                    )
                case .timeline:
                    SongTimelineRowContent(
                        song: song,
                        title: library.displayTitle(for: song),
                        artist: library.artistDisplayName(for: song),
                        ordinal: ordinal,
                        isPlaying: player.currentSong?.id == song.id,
                        isSelected: membership.isSelected
                    )
                case .artwork:
                    SongArtworkRowContent(
                        song: song,
                        title: library.displayTitle(for: song),
                        artist: library.artistDisplayName(for: song),
                        ordinal: ordinal,
                        isPlaying: player.currentSong?.id == song.id,
                        isSelected: membership.isSelected
                    )
                }
            } else {
                SongRowView(
                    song: song,
                    isPlaying: player.currentSong?.id == song.id,
                    trackNumber: ordinal,
                    largestTrackNumber: totalCount,
                    // 时间线卡片与封面胶囊上没有地方放「⋯」，单曲操作走长按菜单。
                    showsActions: appearance == .list,
                    selection: selection,
                    listAppearance: appearance,
                    context: SongRowView.context(
                        for: song,
                        sourcesStore: sourcesStore,
                        backfill: backfill
                    )
                )
            }
        }
        .songLocationRow(song.id, assignsScrollID: false, appearance: appearance)
        .task(id: scenePhase == .active ? song.id : nil) {
            guard scenePhase == .active, sourcesStore.source(id: song.sourceID)?.type == .local else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            backfill.verifyVisibleLocalFile?(song)
        }
        // 时间线与封面只有卡片、封面与节点算这一行：邻居伸过来的大封面落在这一行空着的半边，点的是邻居。
        .songListRowHitRegion(appearance)
        .onTapGesture {
            if selection.isActive {
                selection.toggle(song.id)
            } else {
                onPlay(song)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(
            selection.isActive
                ? (isSelected ? [.isButton, .isSelected] : .isButton)
                : .isButton
        )
        .accessibilityValue(selection.isActive
            ? Text(isSelected
                ? "library_folder_selection_all"
                : "library_folder_selection_none")
            : Text(verbatim: ""))
        .accessibilityAction(named: Text("batch_select")) {
            if selection.isActive {
                selection.toggle(song.id)
            } else {
                selection.activate(seed: song.id)
            }
        }
        .accessibilityAction(named: Text("play")) {
            onPlay(song)
        }
    }
}

/// Selection scrolling deliberately uses a compact row instead of the full
/// single-song interaction tree. The regular row owns menus, sheets, alerts,
/// offline-cache work, and metadata recovery actions; none of those are
/// reachable while batch selection is active, but constructing them for every
/// newly visible row made large flat lists hitch during a drag.
private struct IOSSelectionSongRow: View {
    @AppStorage(LibraryRowNumberPreferences.storageKey)
    private var showsRowNumbers = LibraryRowNumberPreferences.defaultValue
    @Environment(MusicLibrary.self) private var library

    let song: Song
    let isPlaying: Bool
    let ordinal: Int
    let totalCount: Int
    let membership: SongSelectionMembership

    var body: some View {
        HStack(spacing: 12) {
            SongSelectionCheckmark(isSelected: membership.isSelected)
                .frame(width: 28, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SongRowTrackNumber(number: ordinal, largestNumber: totalCount)
                    Text(song.title)
                        .font(.subheadline)
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                }

                Text(verbatim: selectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [showsRowNumbers ? ordinal.formatted() : nil, song.title, library.artistDisplayName(for: song)]
            .compactMap { $0 }
            .joined(separator: " — ")))
    }

    private var selectionSubtitle: String {
        [library.artistDisplayName(for: song), song.albumTitle]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

// MARK: - Folder maintenance

/// 文件夹页「重新读取文件标签」的进度。iPhone 文件夹页与 Mac 内嵌文件夹浏览各持一份，
/// 离开页面就随页面释放；读取本身在回填服务里继续跑完。
@MainActor
@Observable
final class LibraryFolderMaintenanceModel {
    private(set) var rereadProgress: MetadataTagRereadProgress?
    private(set) var isRereading = false
    @ObservationIgnored private var rereadTask: Task<Void, Never>?

    func rereadTags(songIDs: [String], sourceID: String, backfill: MetadataBackfillService) {
        let readable = songIDs.filter { backfill.canRereadTags(songID: $0, expectedSourceID: sourceID) }
        guard rereadTask == nil, !readable.isEmpty else { return }
        isRereading = true
        rereadProgress = MetadataTagRereadProgress(total: readable.count)
        rereadTask = Task { @MainActor [weak self] in
            let result = await backfill.rereadTags(songIDs: readable, expectedSourceID: sourceID) { progress in
                self?.rereadProgress = progress
            }
            self?.rereadProgress = result
            self?.isRereading = false
            self?.rereadTask = nil
        }
    }
}

/// 文件夹页「⋯」里的「增量扫描此目录」与「重新读取文件标签」。服务由页面在自己的视图
/// 层级里取好再交进来：导航栏菜单的宿主拿不到环境（见 `FolderPlaylistMenuButton`）。
@MainActor
struct LibraryFolderMaintenanceActions {
    var rescan: (() -> Void)?
    var rereadTags: (() -> Void)?
    var isRereading = false

    static func make(
        nodeID: LibraryFolderNodeID,
        index: LibraryFolderIndex?,
        songIDs: [String],
        model: LibraryFolderMaintenanceModel,
        scanService: ScanService,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        library: MusicLibrary,
        scraperService: MusicScraperService,
        backfill: MetadataBackfillService
    ) -> LibraryFolderMaintenanceActions? {
        guard nodeID.kind == .folder || nodeID.kind == .scanRoot,
              let source = sourcesStore.source(id: nodeID.sourceID),
              source.isEnabled, !source.isDeleted else { return nil }
        var actions = LibraryFolderMaintenanceActions(isRereading: model.isRereading)
        if ScanService.supportsFolderRescan(source),
           let index,
           let anchor = LibraryFolderRescanAnchor.make(for: nodeID, in: index) {
            actions.rescan = {
                _ = scanService.rescanFolder(
                    of: source,
                    request: SourceFolderRescanRequest(
                        anchorSongID: anchor.songID,
                        levelsAbove: anchor.levelsAbove
                    ),
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourcesStore,
                    scraperService: scraperService
                )
            }
        }
        // 只看前几首判断能不能读：整个文件夹逐首过一遍留到点下去的时候。
        if songIDs.prefix(24).contains(where: {
            backfill.canRereadTags(songID: $0, expectedSourceID: source.id)
        }) {
            actions.rereadTags = {
                model.rereadTags(songIDs: songIDs, sourceID: source.id, backfill: backfill)
            }
        }
        return actions.rescan == nil && actions.rereadTags == nil ? nil : actions
    }
}

private struct LibraryFolderMaintenanceMenuItems: View {
    let actions: LibraryFolderMaintenanceActions

    var body: some View {
        if let rescan = actions.rescan {
            Button(action: rescan) {
                Label("folder_scan_incremental", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("libraryFolder.rescan")
        }
        if let rereadTags = actions.rereadTags {
            Button(action: rereadTags) {
                Label("reread_song_tags", systemImage: "tag")
            }
            .disabled(actions.isRereading)
            .accessibilityIdentifier("libraryFolder.rereadTags")
        }
    }
}

/// 扫描进度只在这一行里读：扫描时 `scanStates` 一秒变好几次，放在页面主体上会让整页
/// 跟着重绘（见扫描时音乐源页卡顿那次的教训）。
private struct LibraryFolderMaintenanceStatus: View {
    @Environment(ScanService.self) private var scanService

    let sourceID: String
    let model: LibraryFolderMaintenanceModel

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var isScanning: Bool {
        scanService.scanStates[sourceID]?.isScanning == true
    }

    private var isBusy: Bool { isScanning || model.isRereading }

    private var message: String? {
        if isScanning {
            return String(localized: "scan_in_progress")
        }
        guard let progress = model.rereadProgress else { return nil }
        if model.isRereading {
            return String(
                format: String(localized: "metadata_status_reread_progress_format"),
                Int64(progress.processed), Int64(progress.total)
            )
        }
        return String(
            format: String(localized: "metadata_status_reread_result_format"),
            Int64(progress.completed), Int64(progress.failed), Int64(progress.skipped)
        )
    }
}

#if os(macOS)
/// Mac 歌曲表格一行里的格子。拆成可比较的独立视图: 父视图每重算一次(补读每写回一批就是
/// 一次), 只有输入真变了的那几行重建, 窗口里其余几十行原样跳过。
private struct MacSongTableRowContent: View, Equatable, Sendable {
    let showsRowNumbers: Bool
    let song: Song
    let ordinal: Int
    let ordinalWidth: CGFloat
    let isCurrent: Bool
    let isEmphasized: Bool
    let liked: Bool
    let plays: Int
    let artistName: String?
    let isDownloaded: Bool
    let sourceName: String?
    let sourceDotColor: Color?
    let columns: [MacSongsColumn]
    let columnWidths: [MacSongsColumn: CGFloat]
    let contentWidth: CGFloat
    let verticalPadding: CGFloat
    let locale: Locale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.showsRowNumbers == rhs.showsRowNumbers
            && lhs.song == rhs.song
            && lhs.ordinal == rhs.ordinal
            && lhs.ordinalWidth == rhs.ordinalWidth
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isEmphasized == rhs.isEmphasized
            && lhs.liked == rhs.liked
            && lhs.plays == rhs.plays
            && lhs.artistName == rhs.artistName
            && lhs.isDownloaded == rhs.isDownloaded
            && lhs.sourceName == rhs.sourceName
            && lhs.sourceDotColor == rhs.sourceDotColor
            && lhs.columns == rhs.columns
            && lhs.columnWidths == rhs.columnWidths
            && lhs.contentWidth == rhs.contentWidth
            && lhs.verticalPadding == rhs.verticalPadding
            && lhs.locale == rhs.locale
    }

    var body: some View {
        HStack(spacing: 12) {
            // # / play indicator
            ZStack {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                        .pmFadeTransition()
                } else if showsRowNumbers {
                    Text(verbatim: ordinal.formatted(.number.locale(locale)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .pmFadeTransition()
                }
            }
            .frame(width: ordinalWidth, alignment: .leading)
            // 换歌时只有当前与上一首的序号格会更新。
            .pmAnimation(.hover, value: isCurrent)

            // Cover
            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id,
                size: 28, cornerRadius: 4,
                sourceID: song.sourceID, filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .frame(width: 32, alignment: .leading)

            ForEach(columns) { column in
                cell(column)
                    .frame(width: columnWidths[column] ?? 0, alignment: column.alignment)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, verticalPadding)
        .pmRowBackground(selected: isEmphasized)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ column: MacSongsColumn) -> some View {
        Group {
            switch column {
            case .title:
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 12.5, weight: isEmphasized ? .semibold : .medium))
                        .foregroundStyle(isEmphasized ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    SongContentRatingBadge(song: song)
                    if liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.brand)
                    }
                }
            case .artist:
                Text(artistName ?? "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .album:
                Text(song.albumTitle ?? "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .format:
                HStack(spacing: 6) {
                    PMFormatPill.forFormat(song.codecFormat.displayName)
                    if let sampleRate = song.formattedSampleRate {
                        Text(verbatim: sampleRate)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
            case .duration:
                Text(song.duration.formattedDuration)
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
            case .plays:
                playCountText(plays)
            case .sourcePlays:
                playCountText(song.serverPlayCount ?? 0)
            case .downloaded:
                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("filter_downloaded"))
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            case .source:
                sourceCell
            case .year:
                Text(song.year.map(String.init) ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            case .rating:
                Text(verbatim: "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            case .dateAdded:
                Text(song.dateAdded, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            case .bitRate:
                Text(song.formattedBitRate ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            case .bitDepth:
                Text(song.formattedBitDepth ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
    }

    @ViewBuilder
    private func playCountText(_ plays: Int) -> some View {
        if plays > 0 {
            Text("\(plays)")
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textMuted)
        } else {
            Text(verbatim: "—")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        }
    }

    private var sourceCell: some View {
        HStack(spacing: 5) {
            if let sourceName {
                Circle()
                    .fill(sourceDotColor ?? PMColor.textFaint)
                    .frame(width: 6, height: 6)
                Text(verbatim: sourceName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
            }
        }
    }
}
#endif

#if os(macOS)
/// 紧凑视图的一行, 同 `MacSongTableRowContent`: 输入没变就不重建。
private struct MacCompactSongRowContent: View, Equatable, Sendable {
    let showsRowNumbers: Bool
    let song: Song
    let ordinal: Int
    let ordinalWidth: CGFloat
    let isCurrent: Bool
    let isEmphasized: Bool
    let liked: Bool
    let artistName: String?
    let locale: Locale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.showsRowNumbers == rhs.showsRowNumbers
            && lhs.song == rhs.song
            && lhs.ordinal == rhs.ordinal
            && lhs.ordinalWidth == rhs.ordinalWidth
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isEmphasized == rhs.isEmphasized
            && lhs.liked == rhs.liked
            && lhs.artistName == rhs.artistName
            && lhs.locale == rhs.locale
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                        .pmFadeTransition()
                } else if showsRowNumbers {
                    Text(verbatim: ordinal.formatted(.number.locale(locale)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .pmFadeTransition()
                }
            }
            .frame(width: showsRowNumbers ? max(28, ordinalWidth) : ordinalWidth, alignment: .leading)
            .pmAnimation(.hover, value: isCurrent)

            HStack(spacing: 5) {
                Text(song.title)
                    .font(.system(size: 12, weight: isEmphasized ? .semibold : .medium))
                    .foregroundStyle(isEmphasized ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                if liked {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(artistName ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                PMFormatPill.forFormat(song.codecFormat.displayName)
                if let sampleRate = song.formattedSampleRate {
                    Text(verbatim: sampleRate)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .frame(width: 100, alignment: .leading)

            Text(song.duration.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        // 与列表视图的行用同一块底：紧凑模式过去没有悬停反馈。
        .pmRowBackground(selected: isEmphasized, cornerRadius: 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }
}
#endif

#if os(macOS)
/// 一行的按钮与右键菜单。`contextMenu` 会在建行时把整个菜单构造一遍, 包在可比较的
/// 容器里之后, 输入没变的行连菜单也不重建; 菜单里读到的离线状态、有声分类变了, 也
/// 只让这一行重算, 不再牵动整张表。动作闭包读的都是共享状态与 `@State`, 用上一次
/// 建行时的闭包结果一样, 比较时不看它们。
private struct MacSongRowContainer<Content: View & Equatable & Sendable, Menu: View>: View, Equatable {
    let content: Content
    let play: () -> Void
    @ViewBuilder let menu: () -> Menu

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
    }

    var body: some View {
        PMScrollingButton(action: play) {
            content
        }
        .contextMenu { menu().labelStyle(.titleAndIcon) }
    }
}
#endif

#if os(macOS)
/// 详情页（专辑、艺人、歌单、智能歌单）曲目行的右键菜单内容。`contextMenu` 在建行时就要拿到菜单内容,
/// 菜单里读的曲库、离线状态、有声分类和多选状态放进这个小视图自己的 body: 建行时只存下闭包、不读,
/// 这些状态变了也只重算这一份菜单, 不牵动整页（道理同上面的 `MacSongRowContainer`）。
struct MacDeferredSongMenu<Items: View>: View {
    @ViewBuilder let items: () -> Items

    var body: some View {
        items()
    }
}

/// Mac 歌曲列表右键菜单里的「重新读取文件标签」。可用条件、文案和 iPhone 长按菜单「编辑」里那一项一样；
/// 补读服务的状态只在这个小视图里读，读标签开始、结束只重算这一项，不牵动整行。
struct MacRereadSongTagsMenuButton: View {
    let song: Song
    let action: () -> Void
    @Environment(MetadataBackfillService.self) private var backfill

    var body: some View {
        if backfill.canRereadTags(for: song) {
            let isReading = backfill.isRereadingTags(songID: song.id)
            Button(action: action) {
                Label(
                    String(localized: isReading ? "reread_song_tags_in_progress" : "reread_song_tags"),
                    systemImage: "arrow.clockwise"
                )
                .labelStyle(.titleAndIcon)
            }
            .disabled(isReading)
        }
    }
}

/// Mac 歌曲列表右键菜单里「改这首歌自身信息」那一段：刮削数据、编辑标签、编辑歌词、重新读取文件标签，
/// 顺序和文案照 iPhone 长按菜单「编辑」。点了交给页面上挂的 `macSongActionHost`。
struct MacSongMetadataMenuItems: View {
    let song: Song
    let perform: (SongRowActionRequest.Action) -> Void

    var body: some View {
        Button {
            perform(.scrape)
        } label: {
            Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                .labelStyle(.titleAndIcon)
        }
        Button {
            perform(.editTags)
        } label: {
            Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                .labelStyle(.titleAndIcon)
        }
        Button {
            perform(.editLyrics)
        } label: {
            Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                .labelStyle(.titleAndIcon)
        }
        MacRereadSongTagsMenuButton(song: song) { perform(.rereadTags) }
    }
}

extension View {
    /// 右键菜单里要弹页面或读文件的几项交给一个不显示的 `SongRowView` 去做：弹出的刮削、标签、歌词页
    /// 和读完的结果提示都和 iPhone 长按菜单同一套。每页挂一次，不挂在会回收的行上。
    func macSongActionHost(_ request: SongRowActionRequest?) -> some View {
        background {
            if let request {
                SongRowView(song: request.song, actionRequest: request)
                    .id(request.id)
            }
        }
    }
}
#endif

/// 歌曲页目录版式按目录建索引时的范围。
struct SongListFolderCatalogScope: Sendable, Equatable {
    let kinds: Set<LibraryCatalogContentKind>?
    let sourceID: String?
}
