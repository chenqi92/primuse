import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers
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
            }
            return
        }
        let scope = WidgetSettings.sharedDataScope()
        let store = SpokenWordStore.shared
        let songs = library.spokenWordSongs
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let books = SpokenWordBookGrouping.books(
            from: songs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
        let shelf = SpokenWordWidgetPolicy.shelfBooks(from: books)

        var coverJobs: [CoverJob] = []
        let entries = shelf.map { book -> SpokenWordShelfSnapshot.Book in
            var coverName: String?
            // The shelf draws a book with its first item's cover; so does this.
            if scope.includesCover, let song = book.items.first.flatMap({ songsByID[$0.id] }) {
                let fileName = SpokenWordWidgetPolicy.coverFileName(forBookID: book.id)
                coverName = fileName
                if !writtenCovers.contains(fileName) {
                    coverJobs.append(CoverJob(
                        songID: song.id,
                        legacyCoverName: song.coverArtFileName,
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

        let keptCovers = Set(entries.compactMap(\.coverImageName))
        let jobs = coverJobs
        let written = await Task.detached(priority: .utility) {
            Self.writeCovers(jobs, keeping: keptCovers)
        }.value
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
    }

    // MARK: - Covers

    private struct CoverJob: Sendable {
        let songID: String
        let legacyCoverName: String?
        let fileName: String
    }

    /// Renders each cover in its own proportions (the widget frames it as a
    /// book) and removes book covers no longer on the shelf. Returns the
    /// names written.
    private nonisolated static func writeCovers(_ jobs: [CoverJob], keeping kept: Set<String>) -> Set<String> {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return [] }
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
        for job in jobs {
            var data = assets.readCoverData(named: assets.expectedCoverFileName(for: job.songID))
            if data == nil, let legacy = job.legacyCoverName, !legacy.isEmpty,
               !legacy.contains("/"), !legacy.contains("://") {
                data = assets.readCoverData(named: legacy)
            }
            let destination = containerURL.appendingPathComponent(job.fileName)
            guard let data, let jpeg = proportionalJPEG(from: data, maxPixelSize: coverPixelSize) else {
                try? fileManager.removeItem(at: destination)
                continue
            }
            if (try? jpeg.write(to: destination, options: .atomic)) != nil {
                written.insert(job.fileName)
            }
        }
        return written
    }

    private nonisolated static func proportionalJPEG(from data: Data, maxPixelSize: Int) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }
}
