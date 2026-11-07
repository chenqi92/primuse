#if os(iOS) || os(macOS)
import Foundation
import Observation
import CryptoKit
import ImageIO
import PrimuseKit

enum ListeningShareText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "ListeningShare", bundle: .main, value: key, comment: "")
    }
    static func error(_ error: Error) -> String {
        if let error = error as? ListeningShareError { return string("error.\(error)") }
        if let error = error as? ListeningShareCodeError { return string("codeError.\(error)") }
        if let error = error as? ListeningShareCodeResolver.Failure { return string("codeError.\(error)") }
        if error is CancellationError { return string("cancelled") }
        return error.localizedDescription
    }
}

struct ListeningShareSelection: Identifiable {
    let id = UUID()
    var title: String
    var stations: [RadioStation] = []
    var podcasts: [PodcastShow] = []
    var settings = false
    var bookSongs: [Song] = []
    var bookURL: URL?
}

private enum ListeningShareWork {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

@MainActor @Observable
final class ListeningShareCoordinator {
    static let shared = ListeningShareCoordinator()
    var incoming: Incoming?
    var error: String?
    struct Incoming: Identifiable {
        let id = UUID()
        let contents: ListeningShareArchive.Contents
        let directory: URL
    }

    func open(_ url: URL) async {
        guard incoming == nil else { error = ListeningShareText.string("finishCurrentImport"); return }
        do { incoming = try await stage(url) }
        catch { self.error = ListeningShareText.error(error) }
    }

    func stage(_ url: URL) async throws -> Incoming {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-share-in-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent("Share.primuseshare")
            let contents = try await ListeningShareWork.run {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= ListeningShareArchive.maximumSize else { throw ListeningShareError.tooLarge }
                if url.pathExtension.lowercased() == "json" {
                    guard size <= ListeningShareJSON.maximumBytes else { throw ListeningShareCodeError.tooLarge }
                    let package = try ListeningShareJSON.decode(Data(contentsOf: url))
                    try ListeningShareArchive.write(package, to: staged)
                } else {
                    try FileManager.default.copyItem(at: url, to: staged)
                }
                try Task.checkCancellation()
                return try ListeningShareArchive.read(staged)
            }
            try Task.checkCancellation()
            return Incoming(contents: contents, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stage(code: String) async throws -> Incoming {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-share-in-\(UUID().uuidString)")
        do {
            let contents = try await ListeningShareWork.run {
                let package = try ListeningShareCode.decode(code)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("Share.primuseshare")
                try ListeningShareArchive.write(package, to: file)
                return try ListeningShareArchive.read(file)
            }
            try Task.checkCancellation()
            return Incoming(contents: contents, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func discard(_ incoming: Incoming) {
        try? FileManager.default.removeItem(at: incoming.directory)
        if self.incoming?.id == incoming.id { self.incoming = nil }
    }
}

@MainActor
enum ListeningShareService {
    struct Export {
        let package: ListeningSharePackage
        let url: URL
        let directory: URL
        let jsonURL: URL?
        let offlineCode: String?
        let codeError: ListeningShareCodeError?
    }
    struct ImportOptions {
        var stationIndices: Set<Int>
        var podcastIndices: Set<Int>
        var bookIndices: Set<Int>
        var settings = false
        var replaceExisting = false
    }
    struct ImportResult {
        var added = 0
        var skipped = 0
        var failures: [String] = []
    }

    static func prepare(_ selection: ListeningShareSelection, includeSettings: Bool,
                        progress: @escaping (Double) -> Void) async throws -> Export {
        let services = AppServices.shared
        var package = ListeningSharePackage(title: selection.title)
        var seen = Set<String>()
        for station in selection.stations {
            guard !station.isDeleted,
                  let key = RadioImportParser.streamIdentityKey(station.streamURL), seen.insert(key).inserted else { continue }
            guard station.sourcePlaybackPath == nil else { throw ListeningShareError.unsafeURL }
            var entry = ListeningSharePackage.Station(station)
            if entry.logo == nil, let name = station.logoFileName {
                entry.logo = MetadataAssetStore.shared.readCoverData(named: name)
            }
            if let logo = entry.logo { entry.logo = try portableLogo(logo) }
            package.stations.append(entry)
        }
        package.podcasts = selection.podcasts.map(ListeningSharePackage.Podcast.init)
        if includeSettings {
            let defaults = UserDefaults.standard
            for key in ListeningShareSettingsPolicy.allowedKeys {
                if let value = defaults.object(forKey: key) {
                    let data = try ListeningShareSettingsPolicy.encode(value)
                    try ListeningShareSettingsPolicy.validate(data, key: key)
                    package.settings[key] = data
                }
            }
            // A custom EQ preset may only exist on this device; export its actual curve.
            let eq = services.playerService.equalizerService
            package.settings["eq.customBands"] = try ListeningShareSettingsPolicy.encode(eq.bands.map(Double.init))
            package.settings["eq.presetId"] = try ListeningShareSettingsPolicy.encode(EQPreset.customID)
            for id in PlayerBackdropSettingsStore.shared.customImageIDs.prefix(8) {
                if let data = PlayerBackdropImageStore.data(id: id) { package.backgrounds.append(try portableImage(data)) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-share-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var assets: [String: URL] = [:]
        do {
            if !selection.bookSongs.isEmpty {
                var tracks: [ListeningSharePackage.Track] = []
                var total = Int64(0)
                for song in selection.bookSongs {
                    guard let source = services.sourcesStore.source(id: song.sourceID),
                          source.isEnabled, !source.isDeleted,
                          MediaRelaySourcePolicy.supports(song: song, sourceType: source.type),
                          song.fileSize <= ListeningShareArchive.maximumSize - total else { throw ListeningShareError.tooLarge }
                    total += song.fileSize
                }
                var completed: Int64 = 0
                for song in selection.bookSongs {
                    try Task.checkCancellation()
                    let asset = ListeningSharePackage.Asset(size: song.fileSize)
                    let file = directory.appendingPathComponent(asset.id)
                    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw ListeningShareError.incompleteFile }
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    let connector = try await services.sourceManager.connectorForSong(song)
                    var offset: Int64 = 0
                    while offset < song.fileSize {
                        try Task.checkCancellation()
                        let count = min(Int64(1024 * 1024), song.fileSize - offset)
                        let data = try await connector.fetchRange(path: song.filePath, offset: offset, length: count, priority: .background)
                        guard data.count == count else { throw ListeningShareError.incompleteFile }
                        try handle.write(contentsOf: data)
                        offset += count; completed += count
                        progress(Double(completed) / Double(max(1, total)))
                    }
                    try handle.synchronize()
                    assets[asset.id] = file; package.assets.append(asset)
                    tracks.append(.init(title: song.title, fileName: safeAudioName(song), assetID: asset.id,
                                        duration: song.duration.isFinite ? max(0, song.duration) : 0,
                                        chapters: services.musicLibrary.generatedChapters(for: song.id) ?? []))
                }
                let first = selection.bookSongs[0]
                var cover: Data?
                if let name = first.coverArtFileName, let data = MetadataAssetStore.shared.readCoverData(named: name) {
                    cover = try portableImage(data)
                }
                package.books = [.init(title: selection.title, author: first.albumArtistName ?? first.artistName,
                                       cover: cover, tracks: tracks)]
            } else if let url = selection.bookURL {
                _ = try ListeningShareURLPolicy.validate(url.absoluteString, publicSharing: true)
                guard ListeningShareArchive.validAudioFileName(url.lastPathComponent) else { throw ListeningShareError.unsafeURL }
                package.books = [.init(title: selection.title, tracks: [.init(title: selection.title,
                    fileName: url.lastPathComponent, publicURL: url.absoluteString)])]
            }
            let checked = try package.validated()
            let file = directory.appendingPathComponent("Primuse.primuseshare")
            let sources = assets
            try await ListeningShareWork.run { try ListeningShareArchive.write(checked, assets: sources, to: file) }
            // The archive owns the bytes now; remove only this export's staging assets.
            for source in assets.values { try? FileManager.default.removeItem(at: source) }
            let formats = try await ListeningShareWork.run { () -> (URL?, String?, ListeningShareCodeError?) in
                guard checked.assets.isEmpty else { return (nil, nil, .requiresFile) }
                let json: Data
                do { json = try ListeningShareJSON.encode(checked) }
                catch let error as ListeningShareCodeError { return (nil, nil, error) }
                let url = directory.appendingPathComponent("Primuse.json")
                try json.write(to: url, options: .atomic)
                do { return (url, try ListeningShareCode.encode(checked), nil) }
                catch let error as ListeningShareCodeError { return (url, nil, error) }
            }
            return Export(package: checked, url: file, directory: directory,
                          jsonURL: formats.0, offlineCode: formats.1, codeError: formats.2)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func apply(_ contents: ListeningShareArchive.Contents, options: ImportOptions) async throws -> ImportResult {
        let package = try contents.package.validated()
        let services = AppServices.shared
        var result = ImportResult()
        for index in package.stations.indices where options.stationIndices.contains(index) {
            try Task.checkCancellation()
            let entry = package.stations[index]
            let key = RadioImportParser.streamIdentityKey(entry.streamURL)
            let existing = services.radioStationsStore.stations.first { RadioImportParser.streamIdentityKey($0.streamURL) == key }
            if existing != nil && (!options.replaceExisting || existing?.isServerMirror == true) { result.skipped += 1; continue }
            var station = entry.makeStation()
            if let existing { station.id = existing.id; station.createdAt = existing.createdAt; station.lastPlayedAt = existing.lastPlayedAt }
            if let logo = station.logoData {
                station.logoData = try portableLogo(logo)
                station.logoFileName = await MetadataAssetStore.shared.storeCover(station.logoData!, for: "radio:\(station.id)")
            }
            services.radioStationsStore.upsert(station)
            result.added += 1
        }
        services.radioStationsStore.flushPendingPersist()
        let podcasts = PodcastStore.shared
        podcasts.loadIfNeeded()
        for index in package.podcasts.indices where options.podcastIndices.contains(index) {
            try Task.checkCancellation()
            let entry = package.podcasts[index]
            do {
                let url = try ListeningShareURLPolicy.validate(entry.feedURL)
                let existing = entry.directoryID.flatMap { podcasts.subscribedShow(directoryID: $0) } ?? podcasts.isSubscribed(feedURL: url)
                if existing != nil && !options.replaceExisting { result.skipped += 1; continue }
                let show: PodcastShow
                if let existing { show = existing }
                else if let directoryID = entry.directoryID {
                    guard let directoryShow = try await PodcastDirectoryService.shared.lookup(directoryID) else {
                        throw PodcastStore.SubscribeError.notInDirectory
                    }
                    show = try await podcasts.subscribe(directoryShow: directoryShow)
                } else { show = try await podcasts.subscribe(feedURL: url) }
                podcasts.updateDefinition(show.id) {
                    $0.folderName = entry.folder; $0.tagNames = entry.tags
                    $0.settings.episodeOrder = entry.settings.episodeOrder
                    $0.settings.skipIntroSeconds = entry.settings.skipIntroSeconds
                    $0.settings.skipOutroSeconds = entry.settings.skipOutroSeconds
                }
                result.added += 1
            } catch is CancellationError { throw CancellationError() }
            catch { result.failures.append(entry.title + ": " + ListeningShareText.error(error)) }
        }
        for index in package.books.indices where options.bookIndices.contains(index) {
            try Task.checkCancellation()
            do {
                if try await importBook(package.books[index], index: index, contents: contents) { result.added += 1 }
                else { result.skipped += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch { result.failures.append(package.books[index].title + ": " + ListeningShareText.error(error)) }
        }
        if options.settings && !package.settings.isEmpty { try applySettings(package); result.added += 1 }
        return result
    }

    private static func importBook(_ book: ListeningSharePackage.Book, index: Int,
                                   contents: ListeningShareArchive.Contents) async throws -> Bool {
        let services = AppServices.shared
        let root = LocalImportService.ensureMusicDirectory()
        let name = "Shared-\(contents.package.id)-\(index)"
        let destination = root.appendingPathComponent(name, isDirectory: true)
        let restoring = FileManager.default.fileExists(atPath: destination.path)
        let receiptName = ".primuse-share-book.json"
        if restoring {
            let receipt = try Data(contentsOf: destination.appendingPathComponent(receiptName))
            guard try JSONDecoder().decode(ListeningSharePackage.Book.self, from: receipt) == book else {
                throw ListeningShareError.invalidPackage
            }
        }
        let staging = root.appendingPathComponent(".share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        var files: [(ListeningSharePackage.Track, String, Int64)] = []
        for (trackIndex, track) in book.tracks.enumerated() {
            try Task.checkCancellation()
            let fileName = String(format: "%05d_", trackIndex + 1) + track.fileName
            let output = staging.appendingPathComponent(fileName)
            if restoring {
                let existing = destination.appendingPathComponent(fileName)
                let size = try existing.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard size.isRegularFile == true, size.isSymbolicLink != true, let bytes = size.fileSize, bytes > 0,
                      track.assetID.flatMap({ id in contents.package.assets.first { $0.id == id }?.size }).map({ $0 == bytes }) ?? true else {
                    throw ListeningShareError.incompleteFile
                }
                files.append((track, fileName, Int64(bytes)))
                continue
            }
            if let asset = track.assetID {
                try await ListeningShareWork.run { try contents.extract(assetID: asset, to: output) }
            } else if let raw = track.publicURL {
                let url = try ListeningShareURLPolicy.validate(raw, publicSharing: true)
                let remaining = ListeningShareArchive.maximumSize - files.reduce(0) { $0 + $1.2 }
                let temporary = try await ListeningShareDownload.download(url, maximumBytes: remaining)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.moveItem(at: temporary, to: output)
            }
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw ListeningShareError.incompleteFile }
            files.append((track, fileName, Int64(size)))
        }
        let source = services.sourcesStore.source(id: LocalImportService.sourceID)
            ?? LocalImportService.makeSource(name: String(localized: "local_import_source_name"))
        if services.sourcesStore.source(id: source.id) == nil { try services.sourcesStore.addDurably(source) }
        else if source.basePath != root.path || !source.isEnabled || source.isDeleted {
            try services.sourcesStore.updateDurably(source.id) {
                $0.basePath = root.path; $0.isEnabled = true; $0.isDeleted = false
            }
        }
        let cover = try book.cover.map(portableImage)
        if !restoring {
            if let cover { try cover.write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic) }
            try JSONEncoder().encode(book).write(to: staging.appendingPathComponent(receiptName), options: .atomic)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: destination)
            committed = true
        }
        var songs: [Song] = []
        for (trackIndex, tuple) in files.enumerated() {
            let (track, fileName, size) = tuple
            let path = "/" + name + "/" + fileName
            let id = SHA256.hash(data: Data("\(source.id):\(path)".utf8)).map { String(format: "%02x", $0) }.joined()
            let artwork = if let cover { await MetadataAssetStore.shared.storeCover(cover, for: id) } else { nil as String? }
            let song = Song(id: id, title: track.title, albumTitle: book.title, artistName: book.author,
                            albumArtistName: book.author, trackNumber: trackIndex + 1, duration: track.duration,
                            fileFormat: AudioFormat.from(fileExtension: URL(fileURLWithPath: fileName).pathExtension) ?? .mp3,
                            filePath: path, sourceID: source.id, fileSize: size, coverArtFileName: artwork)
            songs.append(song)
            if !track.chapters.isEmpty {
                var record = SpokenChapterRecord(id: id, chapters: track.chapters, transcriptFingerprint: "", providerName: "file")
                record.origin = .imported
                services.musicLibrary.saveGeneratedChapterRecord(record)
            }
        }
        let alreadyImported = restoring && songs.allSatisfy { services.musicLibrary.song(id: $0.id) != nil }
        if alreadyImported { return false }
        services.musicLibrary.addSongs(songs, notifyRemovals: false, pruneMissingSongs: false)
        SpokenWordStore.shared.move(songs, to: .spokenWord)
        services.musicLibrary.refreshContentClassification()
        return true
    }

    private static func applySettings(_ package: ListeningSharePackage) throws {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for (key, data) in package.settings { try ListeningShareSettingsPolicy.validate(data, key: key); values[key] = try ListeningShareSettingsPolicy.decode(data) }
        let images = try package.backgrounds.map(portableImage)
        for (key, value) in values where !key.hasPrefix("eq.") { defaults.set(value, forKey: key) }
        if let data = values[PlayerBackdropSettings.storageKey] as? Data {
            let settings = PlayerBackdropSettings.decode(data)
            PlayerBackdropSettingsStore.shared.update { $0 = settings }
        }
        let imageIDs = images.compactMap { PlayerBackdropImageStore.storeProcessed($0) }
        PlayerBackdropSettingsStore.shared.appendCustomImages(imageIDs)
        #if os(iOS)
        let theme = ThemeColorSettings.shared
        theme.mode = AppThemePreferences.colorMode(in: defaults)
        theme.fixedColorHex = defaults.string(forKey: AppThemePreferences.accentHexKey) ?? theme.fixedColorHex
        theme.coverDrivenAmbient = defaults.bool(forKey: AppThemePreferences.coverDrivenAmbientKey)
        theme.ambientStrength = defaults.double(forKey: AppThemePreferences.ambientStrengthKey)
        #endif
        let eq = AppServices.shared.playerService.equalizerService
        if let bands = values["eq.customBands"] as? [Double] { eq.applyPreset(.custom(bands: bands.map(Float.init))) }
        if let enabled = values["eq.enabled"] as? Bool { eq.setEnabled(enabled) }
    }

    private static func safeAudioName(_ song: Song) -> String {
        let stem = String(String.UnicodeScalarView(song.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }.prefix(80)))
        let sourceExtension = URL(fileURLWithPath: song.filePath).pathExtension.lowercased()
        let fileExtension = PrimuseConstants.supportedAudioExtensions.contains(sourceExtension) ? sourceExtension : song.fileFormat.rawValue
        return "\(stem.isEmpty || stem.hasPrefix(".") ? "Audio" : stem).\(fileExtension)"
    }

    private static func portableImage(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpeg = PlayerBackdropImaging.jpegData(image, quality: 0.85), jpeg.count <= 2 * 1024 * 1024 else {
            throw ListeningShareError.invalidPackage
        }
        return jpeg
    }

    private static func portableLogo(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw ListeningShareError.invalidPackage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw ListeningShareError.invalidPackage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= RadioStationValidation.maximumLogoBytes else {
            throw ListeningShareError.invalidPackage
        }
        return output as Data
    }
}
#endif
