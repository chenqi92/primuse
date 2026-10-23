import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PrimuseKit
import WidgetKit

/// Keeps the "continue listening" widget's snapshot in the App Group current.
///
/// Listening moves a book's position every 15 seconds, and each save posts
/// a change. Rewriting the snapshot and reloading the widget on every one of
/// them would spend the widget's refresh budget on nothing visible, so a
/// publish is debounced, and it only writes when the widget would draw
/// something different: other books, another part, a whole percent more or a
/// minute less left (`SpokenWordWidgetPolicy.signature`).
@MainActor
final class SpokenWordWidgetPublisher {
    static let widgetKind = "SpokenWordShelfWidget"
    /// The listening desk can show a book in either of its tiles.
    private static let deskWidgetKind = "ListeningDeskWidget"
    private static let debounce: Duration = .seconds(2)
    /// Book covers are drawn at most this big in the widget.
    private nonisolated static let coverPixelSize = 360

    private let library: MusicLibrary
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var lastSignature: String?
    /// Covers written in this launch, so a book's cover is rendered once
    /// rather than on every publish. A new launch refreshes them.
    private var writtenCovers: Set<String> = []
    /// 本机封面缓存里没有、这次启动已经去源上取过的书封。只试一次:进度每 15 秒存一次就发布一回,
    /// 真没有封面的书不该每次都连一趟网盘。之后缓存里有了(比如在 App 里看过这本书)照样会用上。
    private var sourceCoverAttempts: Set<String> = []

    init(library: MusicLibrary) {
        self.library = library
    }

    func start() {
        for name in [Notification.Name.primuseSpokenWordDidChange, .primuseSpokenWordClassificationDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observeLibrary()
        schedule()
    }

    /// Books appear and go with the library, not only with listening.
    private func observeLibrary() {
        withObservationTracking {
            _ = library.spokenWordSongs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observeLibrary()
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        guard WidgetSettings.syncEnabled() else {
            if lastSignature != nil || SpokenWordShelfSnapshot.load() != nil {
                SpokenWordShelfSnapshot.clear()
                lastSignature = nil
                WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
                WidgetCenter.shared.reloadTimelines(ofKind: Self.deskWidgetKind)
            }
            return
        }
        let scope = WidgetSettings.sharedDataScope()
        let store = SpokenWordStore.shared
        // 分书要把整个有声书库过一遍，上千条时要一百多毫秒；进度每 15 秒存一次就来一回，
        // 放在主线程上会周期性地打断播放页的动画。这里只取快照，分书与写封面都在后台做。
        let songs = library.spokenWordSongs
        let positions = store.positions
        let finishedAt = store.finishedAt
        let archived = store.archivedBookIDs
        let alreadyWritten = writtenCovers
        let (entries, cachedWrite) = await Task.detached(priority: .utility) {
            let shelf = Self.shelfEntries(
                songs: songs,
                positions: positions,
                finishedAt: finishedAt,
                archived: archived,
                scope: scope,
                alreadyWritten: alreadyWritten
            )
            let keptCovers = Set(shelf.entries.compactMap(\.coverImageName))
            return (shelf.entries, Self.writeCovers(shelf.coverJobs, keeping: keptCovers))
        }.value
        var written = cachedWrite.written
        // 本机缓存里没有的书封(文件夹里的 cover.jpg、服务器给的封面地址、还没缓存过的内嵌封面)
        // 照书架的取法去源上取一次,书架有封面、小组件却是占位图的就是这一类(#313)。
        let sourceJobs = cachedWrite.missing.filter { !sourceCoverAttempts.contains($0.fileName) }
        if !sourceJobs.isEmpty {
            sourceCoverAttempts.formUnion(sourceJobs.map(\.fileName))
            let sourceManager = AppServices.shared.sourceManager
            let fetched = await Task.detached(priority: .utility) {
                await Self.writeSourceCovers(sourceJobs, sourceManager: sourceManager)
            }.value
            written.formUnion(fetched)
        }
        writtenCovers.formUnion(written)
        // A cover that could not be rendered is left to the placeholder
        // rather than pointing the widget at a missing file.
        let finalEntries = entries.map { entry -> SpokenWordShelfSnapshot.Book in
            guard let name = entry.coverImageName,
                  !written.contains(name),
                  !writtenCovers.contains(name) else { return entry }
            var entry = entry
            entry.coverImageName = nil
            return entry
        }

        let signature = SpokenWordWidgetPolicy.signature(of: finalEntries)
            + (scope.includesProgress ? "" : "\u{1D}noprogress")
        guard signature != lastSignature else { return }
        lastSignature = signature
        SpokenWordShelfSnapshot(books: finalEntries).save()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.deskWidgetKind)
    }

    /// The widget's books, as the shelf groups them, and the covers still to
    /// render. Runs off the main actor on a snapshot of the library and the
    /// stored progress.
    private nonisolated static func shelfEntries(
        songs: [Song],
        positions: [String: SpokenWordStore.StoredPosition],
        finishedAt: [String: Date],
        archived: Set<String>,
        scope: WidgetSharedDataScope,
        alreadyWritten: Set<String>
    ) -> (entries: [SpokenWordShelfSnapshot.Book], coverJobs: [CoverJob]) {
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let books = SpokenWordBookGrouping.books(from: songs.map { song in
            let stored = positions[song.id]
            return SpokenWordBookItem(
                song: song,
                knownDuration: stored?.duration,
                position: stored?.position,
                positionUpdatedAt: stored?.updatedAt,
                finishedAt: finishedAt[song.id]
            )
        })
        let shelf = SpokenWordWidgetPolicy.shelfBooks(from: books, archivedBookIDs: archived)

        var coverJobs: [CoverJob] = []
        let entries = shelf.map { book -> SpokenWordShelfSnapshot.Book in
            var coverName: String?
            // The shelf draws a book with its first item's cover; so does this.
            if scope.includesCover, let song = book.items.first.flatMap({ songsByID[$0.id] }) {
                let fileName = SpokenWordWidgetPolicy.coverFileName(forBookID: book.id)
                coverName = fileName
                if !alreadyWritten.contains(fileName) {
                    coverJobs.append(CoverJob(
                        songID: song.id,
                        legacyCoverName: song.coverArtFileName,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        fileName: fileName
                    ))
                }
            }
            var entry = SpokenWordWidgetPolicy.shelfEntry(for: book, coverImageName: coverName)
            if !scope.includesProgress {
                entry.fractionComplete = 0
                entry.remaining = nil
            }
            return entry
        }
        return (entries, coverJobs)
    }

    // MARK: - Covers

    private struct CoverJob: Sendable {
        let songID: String
        let legacyCoverName: String?
        let sourceID: String
        let filePath: String
        let fileFormat: AudioFormat
        let fileName: String
    }

    /// Renders each cover as a square the way the shelf draws a book (see
    /// `WidgetBookCoverRenderer`) and removes book covers no longer on the
    /// shelf. Returns the names written, and the jobs whose cover is not in
    /// the local cover cache.
    private nonisolated static func writeCovers(
        _ jobs: [CoverJob],
        keeping kept: Set<String>
    ) -> (written: Set<String>, missing: [CoverJob]) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return ([], []) }
        let fileManager = FileManager.default
        if let existing = try? fileManager.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil) {
            for url in existing
            where url.lastPathComponent.hasPrefix(SpokenWordWidgetPolicy.coverFilePrefix)
                && !kept.contains(url.lastPathComponent) {
                try? fileManager.removeItem(at: url)
            }
        }
        let assets = MetadataAssetStore.shared
        var written: Set<String> = []
        var missing: [CoverJob] = []
        for job in jobs {
            var data = assets.readCoverData(named: assets.expectedCoverFileName(for: job.songID))
            if data == nil, let legacy = job.legacyCoverName, !legacy.isEmpty,
               !legacy.contains("/"), !legacy.contains("://") {
                data = assets.readCoverData(named: legacy)
            }
            let destination = containerURL.appendingPathComponent(job.fileName)
            guard let data, let jpeg = WidgetBookCoverRenderer.squareJPEG(
                from: data,
                pixelSize: coverPixelSize,
                keepsWholeCover: true,
                quality: 0.82
            ) else {
                try? fileManager.removeItem(at: destination)
                missing.append(job)
                continue
            }
            if (try? jpeg.write(to: destination, options: .atomic)) != nil {
                written.insert(job.fileName)
            }
        }
        return (written, missing)
    }

    /// 本机缓存里没有的书封,和书架同一条路取(`CachedArtworkView.resolveImage`:缓存、
    /// 文件夹封面图、服务器封面、文件里的内嵌封面),再按书封的画法写成小组件用的方图。
    private nonisolated static func writeSourceCovers(
        _ jobs: [CoverJob],
        sourceManager: SourceManager
    ) async -> Set<String> {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return [] }
        var written: Set<String> = []
        for job in jobs {
            guard !Task.isCancelled else { break }
            let image = await CachedArtworkView.resolveImage(
                coverRef: job.legacyCoverName,
                songID: job.songID,
                size: CGFloat(coverPixelSize),
                sourceID: job.sourceID,
                filePath: job.filePath,
                fileFormat: job.fileFormat,
                sourceManager: sourceManager
            )
            guard let cgImage = image?.platformCGImage,
                  let square = WidgetBookCoverRenderer.squareImage(
                      cgImage,
                      pixelSize: coverPixelSize,
                      keepsWholeCover: true
                  ),
                  let jpeg = PlayerBackdropImaging.jpegData(square, quality: 0.82) else { continue }
            if (try? jpeg.write(to: containerURL.appendingPathComponent(job.fileName), options: .atomic)) != nil {
                written.insert(job.fileName)
            }
        }
        return written
    }

}

/// 小组件里的书封成图，和 App 里 `bookCoverLayout` 同一个画法：方图直接铺满；
/// 竖版、横版的封面整张放进方框，空出来的边垫同一张图放大后的模糊底，再压一层 16% 的黑。
/// 模糊在 App 这边写图时一次烘好：小组件进程内存很紧，每次刷新时间线都现场模糊也不划算。
enum WidgetBookCoverRenderer {
    /// 「正在播放」封面的去重键：同一首歌按书封画过和按普通封面画过算两张图；这首歌的
    /// 封面换过（`coverContent` 变了）也算另一张，以前歌没换，小组件就一直是旧封面。
    nonisolated static func coverKey(songID: String, keepsWholeCover: Bool, coverContent: String? = nil) -> String {
        let key = keepsWholeCover ? songID + "\u{1F}book" : songID
        return coverContent.map { key + "\u{1F}" + $0 } ?? key
    }

    /// 这首歌眼下那张封面是哪一份，只读文件头、不解码。和写小组件封面时同一个找法：
    /// 先按歌曲 id，再按它的封面引用。
    nonisolated static func coverContent(for song: Song) -> String? {
        let store = MetadataAssetStore.shared
        if let identity = store.coverContentIdentifier(named: store.expectedCoverFileName(for: song.id)) {
            return identity
        }
        guard let ref = song.coverArtFileName, !ref.isEmpty,
              !ref.contains("/"), !ref.contains("://") else { return nil }
        return store.coverContentIdentifier(named: ref)
    }

    /// 解码 `data` 并画成 `pixelSize` 见方的 JPEG。`keepsWholeCover` 为 false 时就是居中裁切铺满。
    nonisolated static func squareJPEG(
        from data: Data,
        pixelSize: Int,
        keepsWholeCover: Bool,
        quality: Double = 0.8
    ) -> Data? {
        autoreleasepool {
            guard pixelSize > 0,
                  let source = CGImageSourceCreateWithData(data as CFData, [
                      kCGImageSourceShouldCache: false,
                  ] as CFDictionary) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize * 2,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  let square = squareImage(image, pixelSize: pixelSize, keepsWholeCover: keepsWholeCover) else {
                return nil
            }
            return PlayerBackdropImaging.jpegData(square, quality: quality)
        }
    }

    nonisolated static func squareImage(_ image: CGImage, pixelSize: Int, keepsWholeCover: Bool) -> CGImage? {
        guard pixelSize > 0, image.width > 0, image.height > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let side = CGFloat(pixelSize)
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        let imageSize = CGSize(width: image.width, height: image.height)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(canvas)

        // 和书架同一个容差：差一两个像素的「方图」照样铺满，不垫一圈看不见的模糊。
        if !keepsWholeCover || SpokenWordCoverLayout.artworkFillsFrame(imageSize: imageSize, frameAspectRatio: 1) {
            context.draw(image, in: centeredRect(for: imageSize, side: side, filling: true))
            return context.makeImage()
        }

        if let backdrop = blurredFill(image, side: side) {
            context.draw(backdrop, in: canvas)
        } else {
            context.draw(image, in: centeredRect(for: imageSize, side: side, filling: true))
        }
        context.setFillColor(CGColor(gray: 0, alpha: 0.16))
        context.fill(canvas)
        context.saveGState()
        // App 里那层封面带一道很浅的投影（22% 黑、半径 3、下移 1），按画布比例换算。
        context.setShadow(
            offset: CGSize(width: 0, height: -side * 0.008),
            blur: side * 0.025,
            color: CGColor(gray: 0, alpha: 0.22)
        )
        context.draw(image, in: centeredRect(for: imageSize, side: side, filling: false))
        context.restoreGState()
        return context.makeImage()
    }

    /// 居中摆放：`filling` 为 true 时铺满后裁掉多出的部分，否则整张放进方框。
    /// 两个方向对称，所以 Core Graphics 的 y 轴朝上也不影响构图。
    private nonisolated static func centeredRect(for imageSize: CGSize, side: CGFloat, filling: Bool) -> CGRect {
        let widthScale = side / imageSize.width
        let heightScale = side / imageSize.height
        let scale = filling ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
    }

    /// 铺满方框后整体模糊。先 clamp 边缘再模糊，四周不会被透明像素冲淡发灰（App 里是 `opaque: true`）。
    private nonisolated static func blurredFill(_ image: CGImage, side: CGFloat) -> CGImage? {
        let scale = max(side / CGFloat(image.width), side / CGFloat(image.height))
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent
        let crop = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(side * 0.08))
            .cropped(to: crop)
        return ciContext.createCGImage(blurred, from: crop)
    }

    // CIContext 本身线程安全，写书封的几处共用一份。
    private nonisolated static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])
}
