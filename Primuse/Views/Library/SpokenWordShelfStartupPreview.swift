import Foundation
import PrimuseKit
import SwiftUI

extension EnvironmentValues {
    /// 书架正在画启动快照(见 `SpokenWordShelfStartupHost`): 书只用来看和点进去, 菜单、排序这些不给。
    @Entry var spokenWordShelfStartupPreview = false
}

/// 书架的外层。冷启动时曲库还在读, 读完了书还要在后台分组, 两段加起来大曲库上要好几秒:
/// 这期间先按上次落盘的首屏快照(`SpokenWordShelfStartupSnapshot`)摆出同样版式的书架,
/// 分好组后原地换成真的书架 —— 同一个视图、同样的书 id, 封面、位置和滚动都不动。
/// 没有快照(刚装好、没开过书架、换过音乐源)时画书架形状的骨架。
///
/// 书架分好组以后, 书的集合或顺序变了就把新的首屏写回去; 进度只在离开这一页、App 退到后台时带上。
struct SpokenWordShelfStartupHost<Content: View>: View {
    let books: SpokenWordBooksModel
    @ViewBuilder var content: (SpokenWordLibrarySnapshot) -> Content

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SpokenWordShelfOrder.storageKey) private var savedOrder = ""
    @State private var preview: SpokenWordLibrarySnapshot?
    @State private var isVisible = false

    private struct RecordKey: Equatable {
        let generation: UInt
        let isSettled: Bool
        let order: String
        let playingBookID: String?
    }

    /// 只在读写快照时取, 不进 body。书架页也放在没注入音乐源的地方(调试页、测试), 所以不从环境里拿。
    private var enabledSourceIDs: Set<String> {
        Set(AppServices.shared.sourcesStore.sources.filter(\.isEnabled).map(\.id))
    }

    var body: some View {
        let settled = books.isSettled
        // A zero-height initial shelf can be skipped by its parent's lazy stack.
        ZStack(alignment: .top) {
            if let shown = settled ? Optional(books.snapshot) : preview {
                // 「正在准备资料库」画在书架标题那一行(`SpokenWordShelfContent`),不在页尾。
                content(shown)
                    .environment(\.spokenWordShelfStartupPreview, !settled)
                    .pmFadeTransition(motion: .contentAppear)
            } else {
                SpokenWordShelfSkeleton()
                    .pmFadeTransition(motion: .contentAppear)
            }
        }
        .task(id: settled) {
            guard !settled else {
                if preview != nil { preview = nil }
                return
            }
            guard preview == nil else { return }
            let loaded = await SpokenWordShelfStartupFile.loadPreview(sourceIDs: enabledSourceIDs)
            guard !Task.isCancelled, !books.isSettled, let loaded else { return }
            preview = loaded
        }
        .task(id: RecordKey(
            generation: books.snapshotGeneration, isSettled: settled,
            order: savedOrder, playingBookID: player.currentBookID
        )) {
            guard books.isSettled else { return }
            // 分组结果一阵一阵地来(扫描、补读标签、听书存进度), 停两秒再记; 记的时候在后台比一比,
            // 只是进度往前走了就不写。
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            record(includingProgress: false)
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            record(includingProgress: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, isVisible else { return }
            record(includingProgress: true)
        }
    }

    private func record(includingProgress: Bool) {
        guard books.isSettled else { return }
        SpokenWordShelfStartupStore.shared.record(
            books.snapshot,
            shelfOrder: savedOrder,
            playingBookID: player.currentBookID,
            sourceIDs: enabledSourceIDs,
            includingProgress: includingProgress
        )
    }
}

/// 书架还在读时标题那一行右边的「正在准备资料库」:一个小转圈加一行字。
struct SpokenWordShelfPreparingStatus: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("library_preparing")
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .pmFadeTransition(motion: .contentAppear)
    }
}

/// 没有启动快照时书架的骨架: 照用户选的版式画网格或行, 网格和真书架同样的列宽与书封比例。
/// 很快就分好组时只铺空白, 免得骨架闪一下。
private struct SpokenWordShelfSkeleton: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("spokenWord.shelf.layout") private var layout = SpokenWordShelfLayout.bookshelf
    @State private var isVisible = false
    @State private var isDimmed = false

    /// 和 `SpokenWordShelfContent` 的网格一致。
    private var gridColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 18, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 14, alignment: .top)]
        #endif
    }

    private var fill: Color { Color.secondary.opacity(0.14) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(maxWidth: .infinity, minHeight: 120)
            if isVisible {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        bar(width: 72, height: 18)
                            .opacity(isDimmed ? 0.55 : 1)
                        Spacer(minLength: 12)
                        // 和真书架标题那一行同一个位置,换成真书架时不挪。
                        if !library.isReady {
                            SpokenWordShelfPreparingStatus()
                        }
                    }
                    .frame(minHeight: 44)
                    Group {
                        if layout.isGrid {
                            grid
                        } else {
                            rows
                        }
                    }
                    .opacity(isDimmed ? 0.55 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("library_preparing"))
                }
                .pmFadeTransition(motion: .contentAppear)
            }
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isVisible = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDimmed = true }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: gridColumns, spacing: layout == .covers ? 14 : 22) {
            ForEach(0..<9, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                        .aspectRatio(SpokenWordCoverLayout.aspectRatio, contentMode: .fit)
                    if layout == .bookshelf {
                        bar(width: 80, height: 10)
                            .padding(.top, 6)
                        bar(width: 52, height: 8)
                    }
                }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                        .frame(width: 54, height: SpokenWordCoverLayout.height(forWidth: 54))
                    VStack(alignment: .leading, spacing: 8) {
                        bar(width: index.isMultiple(of: 3) ? 150 : 200, height: 12)
                        bar(width: index.isMultiple(of: 2) ? 90 : 120, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
    }
}

/// 书架首屏快照的读写。文件在曲库启动缓存的那个目录里, 只在本机; 删了音乐源、有声内容都没了就删掉,
/// 开着的音乐源和写下时不一样时不拿来画。
@MainActor
final class SpokenWordShelfStartupStore {
    static let shared = SpokenWordShelfStartupStore()

    private let writer = SpokenWordShelfStartupWriter()
    private var generation: UInt64 = 0
    /// 删过以后还没再记过: 有声内容一直是空的时不必一遍遍去删。
    private var isCleared = false

    /// 跟着有声内容走: 装好的曲库里一本书也没有了(有声归属关掉、书都移成音乐、源里的书没了)就删掉,
    /// 书架页没开着也不留着上次的书名。
    func follow(library: MusicLibrary) {
        library.onReady { [weak self, weak library] in
            guard let self, let library else { return }
            self.observeSpokenWordContent(in: library)
        }
    }

    private func observeSpokenWordContent(in library: MusicLibrary) {
        let hasContent = withObservationTracking {
            library.hasSpokenWordContent
        } onChange: { [weak self, weak library] in
            Task { @MainActor [weak self, weak library] in
                guard let self, let library else { return }
                self.observeSpokenWordContent(in: library)
            }
        }
        if !hasContent { clear() }
    }

    /// 记下分好组的书架。挑书、比较、写盘都在后台; `includingProgress` 为 false 时只在书的集合、
    /// 顺序、书名封面或在哪一节变了时写。
    func record(
        _ snapshot: SpokenWordLibrarySnapshot,
        shelfOrder: String,
        playingBookID: String?,
        sourceIDs: Set<String>,
        includingProgress: Bool
    ) {
        isCleared = false
        generation &+= 1
        let generation = generation
        let writer = writer
        let url = SpokenWordShelfStartupFile.url
        Task.detached(priority: .utility) {
            let stored = SpokenWordShelfStartupFile.makeSnapshot(
                from: snapshot, shelfOrder: shelfOrder, playingBookID: playingBookID, sourceIDs: sourceIDs
            )
            await writer.commit(stored, generation: generation, includingProgress: includingProgress, url: url)
        }
    }

    /// 删掉快照(删了音乐源、有声内容都没了)。
    func clear() {
        guard !isCleared else { return }
        isCleared = true
        generation &+= 1
        let generation = generation
        let writer = writer
        let url = SpokenWordShelfStartupFile.url
        Task.detached(priority: .utility) {
            await writer.commit(nil, generation: generation, includingProgress: true, url: url)
        }
    }
}

enum SpokenWordShelfStartupFile {
    static var url: URL {
        FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("spoken-word-shelf-startup.plist")
    }

    /// 读快照并拼成书架能画的一份。读盘、解码、拼书都在后台; 开着的音乐源和写下时不一样就是 nil。
    static func loadPreview(sourceIDs: Set<String>) async -> SpokenWordLibrarySnapshot? {
        let fileURL = Self.url
        let worker = Task.detached(priority: .userInitiated) { () -> SpokenWordLibrarySnapshot? in
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  let stored = SpokenWordShelfStartupSnapshot.decode(data),
                  stored.matches(sourceIDs: sourceIDs), !stored.books.isEmpty,
                  !Task.isCancelled else { return nil }
            return SpokenWordShelfStartupFile.previewSnapshot(from: stored)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func previewSnapshot(from stored: SpokenWordShelfStartupSnapshot) -> SpokenWordLibrarySnapshot {
        var covers: [String: Song] = [:]
        for book in stored.books {
            if let cover = book.cover { covers[book.id] = cover.makeSong() }
        }
        return SpokenWordLibrarySnapshot(
            books: stored.books.map { $0.makeBook() },
            archivedBookIDs: Set(stored.books.filter(\.isArchived).map(\.id)),
            previewCovers: covers
        )
    }

    /// 从分好组的书架挑出首屏要的书(`SpokenWordShelfStartupPolicy`), 按分组的先后存。
    /// 一本书也没有时是 nil: 文件删掉。
    static func makeSnapshot(
        from snapshot: SpokenWordLibrarySnapshot,
        shelfOrder: String,
        playingBookID: String?,
        sourceIDs: Set<String>
    ) -> SpokenWordShelfStartupSnapshot? {
        let grouped = snapshot.activeEntries + snapshot.archived
        guard !grouped.isEmpty else { return nil }
        let preferred = SpokenWordShelfOrder.decode(shelfOrder)
        func displayed(_ entries: [SpokenWordLibrarySnapshot.Entry]) -> [String] {
            SpokenWordShelfOrder.orderedIDs(entries.map(\.id), preferred: preferred)
        }
        // 和书架页一样: 正在放的那本算「在听」。
        let shown = snapshot.listening(to: playingBookID)
        let kept = SpokenWordShelfStartupPolicy.keptBookIDs(
            listening: shown.listeningEntries.map(\.id),
            // 书架一节和书架页一样连在听的书一起按原位排。
            shelf: displayed(snapshot.shelfInPlace),
            finished: displayed(shown.finished),
            archived: displayed(shown.archived)
        )
        let archivedIDs = Set(snapshot.archived.map(\.id))
        let books = grouped.filter { kept.contains($0.id) }.map { entry in
            SpokenWordShelfStartupSnapshot.Book(
                book: entry.book,
                isArchived: archivedIDs.contains(entry.id),
                cover: entry.coverSong.map { SpokenWordShelfStartupSnapshot.Cover(song: $0) }
            )
        }
        return SpokenWordShelfStartupSnapshot(sourceIDs: sourceIDs, books: books)
    }
}

/// 一个一个地写, 晚到的旧结果不盖新的。记着上次写下的那份(启动后第一次从盘上读回来), 没变就不写。
private actor SpokenWordShelfStartupWriter {
    private var latestGeneration: UInt64 = 0
    private var written: SpokenWordShelfStartupSnapshot?
    private var hasReadWritten = false

    func commit(
        _ snapshot: SpokenWordShelfStartupSnapshot?,
        generation: UInt64,
        includingProgress: Bool,
        url: URL
    ) {
        guard generation > latestGeneration else { return }
        latestGeneration = generation
        if !hasReadWritten {
            hasReadWritten = true
            written = (try? Data(contentsOf: url)).flatMap { SpokenWordShelfStartupSnapshot.decode($0) }
        }
        guard let snapshot, !snapshot.books.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            written = nil
            return
        }
        if let written {
            let unchanged = includingProgress ? written == snapshot : written.structure == snapshot.structure
            if unchanged { return }
        }
        guard let data = try? snapshot.encoded() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            written = snapshot
        } catch {
            plog("Spoken word shelf startup snapshot not written: \(error.localizedDescription)")
        }
    }
}
