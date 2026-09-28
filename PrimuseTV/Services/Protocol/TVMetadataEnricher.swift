#if os(tvOS)
import Foundation
import PrimuseKit

enum TVMetadataEnrichmentStatus: Sendable, Equatable {
    case enriched
    case failed
    case timedOut
    case cancelled
}

struct TVMetadataEnrichmentResult: Sendable {
    let song: Song
    let status: TVMetadataEnrichmentStatus
    let errorDescription: String?
    var inspectionComplete = false
}

private enum TVMetadataError: Error {
    case readerUnavailable
    case emptyHeader
    case invalidDescriptor
}

private actor TVResolvedStreamMetadataReader: ByteRangeReader {
    private let resolved: ResolvedStream
    private let session: URLSession
    private var knownContentLength: Int64?

    init(resolved: ResolvedStream, contentLength: Int64, session: URLSession) {
        self.resolved = resolved
        self.session = session
        knownContentLength = contentLength > 0 ? contentLength : nil
    }

    func contentLength() async throws -> Int64 {
        try Task.checkCancellation()
        if let knownContentLength { return knownContentLength }
        let (_, total) = try await fetch(offset: 0, length: 2)
        knownContentLength = total
        return total
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, length > 0 else { return Data() }
        let (data, total) = try await fetch(offset: offset, length: length)
        try Task.checkCancellation()
        if let knownContentLength, knownContentLength != total {
            throw URLError(.badServerResponse)
        }
        knownContentLength = total
        return data
    }

    private func fetch(offset: Int64, length: Int64) async throws -> (Data, Int64) {
        guard let range = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return (Data(), knownContentLength ?? 0)
        }
        var request = URLRequest(url: resolved.url)
        for (key, value) in resolved.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 12

        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            maximumBytes: Int(clamping: length)
        )
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 206:
            guard let total = HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length")
                    .flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw URLError(.badServerResponse)
            }
            return (data, total)
        case 200:
            guard offset == 0,
                  HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                    bodyLength: data.count,
                    requestedOffset: offset,
                    requestedLength: length
                  ) else {
                throw URLError(.badServerResponse)
            }
            return (data, Int64(data.count))
        default:
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
    }
}

/// One pool is created per scan. Protocol readers, resolved cloud URLs and the
/// HTTP session are reused across header/tail/sidecar reads and CUE tracks.
actor TVMetadataReaderPool {
    private struct RangeKey: Hashable, Sendable {
        let path: String
        let offset: Int64
        let length: Int64
    }

    private struct RangeTask {
        let id: UUID
        let task: Task<Data, Error>
    }

    private let source: MusicSource
    private let rereadMetadata: Bool
    private var refreshedAlbumIDs: Set<String> = []
    private let audit = TVMetadataReadAudit()
    var readFailureCount: Int { get async { await audit.failures } }
    func markIncomplete() async { await audit.failed() }
    func takeReadStatistics() async -> TVScanReadStatistics { await audit.takeWindow() }
    private let credential: SourceCredential?
    private let session: URLSession
    private var readers: [String: any ByteRangeReader] = [:]
    private var cachedRanges: [RangeKey: Data] = [:]
    private var cachedRangeBytes = 0
    private var rangeTasks: [RangeKey: RangeTask] = [:]
    private var isClosed = false
    private static let resolvedStreamTypes: Set<MusicSourceType> = [
        .webdav, .oneDrive, .dropbox, .synology, .qnap, .ugreen,
    ]
    private static let maximumCachedRangeBytes = 24 * 1024 * 1024
    private static let maximumIndividualCachedRangeBytes: Int64 = 4 * 1024 * 1024

    init(source: MusicSource, credential: SourceCredential?, rereadMetadata: Bool = false) {
        self.source = source
        self.rereadMetadata = rereadMetadata
        self.credential = credential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = MetadataReadingDeviceProfile.current
            .maximumWorkers(offlineSource: false)
        // 与播放/歌词同一套证书策略(TVServerTrust);没有 delegate 时自签 WebDAV 读标签会报 -1202。
        session = URLSession(configuration: configuration, delegate: TVInsecureTLSDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func refreshesAlbumArtwork(_ albumID: String) -> Bool {
        rereadMetadata && refreshedAlbumIDs.insert(albumID).inserted
    }

    func localURL(path: String) -> URL? {
        guard source.type == .local else { return nil }
        return try? TVLocalTransferSource.url(for: path)
    }

    func reader(path: String, size: Int64) async throws -> any ByteRangeReader {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        if let existing = readers[path] { return existing }
        let reader: any ByteRangeReader
        if let direct = TVPlaybackCoordinator.makeDirectReader(
            source: source,
            filePath: path,
            credential: credential
        ) {
            reader = direct
        } else {
            // NAS 文件站(群晖/威联通/绿联)的下载地址同样支持按段读;以前没列进来,
            // 整轨 CUE 读不到就让整次扫描失败,标签也从没在电视上读出来过。
            guard Self.resolvedStreamTypes.contains(source.type) else {
                throw TVMetadataError.readerUnavailable
            }
            let fileExtension = (path as NSString).pathExtension
            let format = AudioFormat.from(fileExtension: fileExtension) ?? .mp3
            let placeholder = Song(
                id: "metadata-reader:\(path)",
                title: (path as NSString).lastPathComponent,
                fileFormat: format,
                filePath: path,
                sourceID: source.id,
                fileSize: size
            )
            let resolved = try await StreamResolverRegistry.shared.resolve(
                for: placeholder,
                source: source,
                credential: credential
            )
            try Task.checkCancellation()
            reader = TVResolvedStreamMetadataReader(
                resolved: resolved,
                contentLength: size,
                session: session
            )
        }
        guard !isClosed else {
            Task { await reader.close() }
            throw CancellationError()
        }
        let audited = TVAuditedMetadataReader(reader: reader, audit: audit)
        readers[path] = audited
        return audited
    }

    func read(
        path: String,
        size: Int64,
        offset: Int64,
        length: Int64
    ) async throws -> Data {
        let key = RangeKey(path: path, offset: offset, length: length)
        if let cached = cachedRanges[key] { return cached }
        if let inFlight = rangeTasks[key] {
            let data = try await inFlight.task.value
            try Task.checkCancellation()
            return data
        }
        let reader = try await reader(path: path, size: size)
        let taskID = UUID()
        let task = Task {
            try await reader.read(offset: offset, length: length)
        }
        rangeTasks[key] = RangeTask(id: taskID, task: task)
        let data: Data
        do {
            data = try await task.value
        } catch {
            if rangeTasks[key]?.id == taskID { rangeTasks[key] = nil }
            throw error
        }
        if rangeTasks[key]?.id == taskID { rangeTasks[key] = nil }
        if length <= Self.maximumIndividualCachedRangeBytes,
           cachedRangeBytes + data.count <= Self.maximumCachedRangeBytes {
            cachedRanges[key] = data
            cachedRangeBytes += data.count
        }
        try Task.checkCancellation()
        return data
    }

    func contentLength(path: String, size: Int64) async throws -> Int64 {
        let reader = try await reader(path: path, size: size)
        let length = try await reader.contentLength()
        try Task.checkCancellation()
        return length
    }

    func closeAll() async {
        guard !isClosed else { return }
        isClosed = true
        let activeReaders = Array(readers.values)
        let activeTasks = rangeTasks.values.map(\.task)
        readers.removeAll()
        rangeTasks.removeAll()
        cachedRanges.removeAll()
        cachedRangeBytes = 0
        activeTasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
        for reader in activeReaders {
            Task { await reader.close() }
        }
    }
}

/// Reads remote tags only after Phase-A songs are already visible. Every file
/// has a bounded wait and returns a typed outcome so enumeration and metadata
/// failures cannot be confused by the Store.
enum TVMetadataEnricher {
    static let headBytes: Int64 = 256 * 1024
    static let maxArtworkHeadBytes: Int64 = 4 * 1024 * 1024
    private static let maximumSidecarLyricsBytes: Int64 = 512 * 1024
    private static let maximumSidecarArtworkBytes: Int64 = 4 * 1024 * 1024
    private static let tailFormats: Set<String> = [
        "m4a", "mp4", "m4b", "alac", "aac", "m4v", "mov",
    ]
    private static let apeTailTagFormats: Set<String> = ["ape", "wv", "mpc", "tta"]
    private static let id3ContainerTailFormats: Set<String> = ["dff", "aiff", "aif", "wav"]

    static func enrich(
        song: Song,
        sidecars: SidecarDirectoryIndex<TVDirEntry>,
        using readerPool: TVMetadataReaderPool,
        timeoutSeconds: UInt64 = 18
    ) async -> TVMetadataEnrichmentResult {
        let race = TVMetadataRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let worker = Task {
                    do {
                        let failuresBefore = await readerPool.readFailureCount
                        let enriched = try await enrichCore(
                            song: song,
                            sidecars: sidecars,
                            readerPool: readerPool
                        )
                        await race.finish(TVMetadataEnrichmentResult(
                            song: enriched,
                            status: .enriched,
                            errorDescription: nil,
                            inspectionComplete: await readerPool.readFailureCount == failuresBefore
                        ))
                    } catch is CancellationError {
                        await race.finish(TVMetadataEnrichmentResult(
                            song: song,
                            status: .cancelled,
                            errorDescription: nil
                        ))
                    } catch {
                        await race.finish(TVMetadataEnrichmentResult(
                            song: song,
                            status: .failed,
                            errorDescription: error.localizedDescription
                        ))
                    }
                }
                let timeout = Task {
                    do {
                        let boundedSeconds = min(timeoutSeconds, 300)
                        try await Task.sleep(
                            nanoseconds: boundedSeconds * 1_000_000_000
                        )
                    } catch {
                        return
                    }
                    await race.finish(TVMetadataEnrichmentResult(
                        song: song,
                        status: .timedOut,
                        errorDescription: URLError(.timedOut).localizedDescription
                    ))
                }
                Task {
                    await race.install(
                        continuation: continuation,
                        tasks: [worker, timeout]
                    )
                }
            }
        } onCancel: {
            Task {
                await race.finish(TVMetadataEnrichmentResult(
                    song: song,
                    status: .cancelled,
                    errorDescription: nil
                ))
            }
        }
    }

    /// Compatibility surface for the old all-at-once scanner.
    static func enrich(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        siblings: [TVDirEntry],
        timeoutSeconds: UInt64 = 18
    ) async -> Song {
        let pool = TVMetadataReaderPool(source: source, credential: credential)
        let result = await enrich(
            song: song,
            sidecars: SidecarDirectoryIndex(siblings),
            using: pool,
            timeoutSeconds: timeoutSeconds
        )
        await pool.closeAll()
        return result.song
    }

    private static func enrichCore(
        song: Song,
        sidecars: SidecarDirectoryIndex<TVDirEntry>,
        readerPool: TVMetadataReaderPool
    ) async throws -> Song {
        try Task.checkCancellation()
        let reader = try await readerPool.reader(
            path: song.filePath,
            size: song.fileSize
        )
        if song.isStreamDescriptor {
            return try await enrichSTRM(
                song: song,
                sidecars: sidecars,
                reader: reader,
                readerPool: readerPool
            )
        }

        if let url = await readerPool.localURL(path: song.filePath) {
            guard try await reader.contentLength() > 0 else { throw TVMetadataError.emptyHeader }
            let metadata = await FileMetadataReader.read(from: url)
            try Task.checkCancellation()
            return try await attachAssets(
                song: applying(metadata, to: song, duration: metadata.duration ?? 0),
                embeddedLyrics: FileMetadataReader.parsedEmbeddedLyrics(from: metadata),
                embeddedCover: metadata.coverArtData, sidecars: sidecars, readerPool: readerPool
            )
        }

        var head = try await reader.read(offset: 0, length: headBytes)
        try Task.checkCancellation()
        guard !head.isEmpty else { throw TVMetadataError.emptyHeader }
        let ext = RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: song.fileFormat.rawValue,
            signature: AudioFileSignaturePolicy.inspect(head)
        )
        var metadata = await readMetadata(head, ext: ext)
        try Task.checkCancellation()

        if let declared = FileMetadataReader.id3TagByteCount(in: head),
           declared > head.count {
            let expanded = RemoteMetadataReadPolicy.expandedReadSize(
                fileSize: song.fileSize,
                currentByteCount: head.count,
                declaredID3ByteCount: declared,
                metadataInsufficient: false
            ) ?? head.count
            let wanted = min(Int64(expanded), maxArtworkHeadBytes)
            if wanted > Int64(head.count),
               let larger = try? await reader.read(offset: 0, length: wanted),
               !larger.isEmpty {
                try Task.checkCancellation()
                head = larger
                metadata = await readMetadata(head, ext: ext)
            }
        }
        try Task.checkCancellation()

        if ext == "flac" {
            while let expanded = RemoteMetadataReadPolicy.expandedFLACReadSize(
                fileSize: song.fileSize,
                currentData: head
            ) {
                let wanted = min(Int64(expanded), maxArtworkHeadBytes)
                guard wanted > Int64(head.count),
                      let larger = try? await reader.read(offset: 0, length: wanted),
                      larger.count > head.count else { break }
                try Task.checkCancellation()
                head = larger
                metadata = await readMetadata(head, ext: ext)
            }
        }
        try Task.checkCancellation()

        while let expanded = EmbeddedTagMetadataParser.expandedHeadReadSize(
            fileSize: song.fileSize,
            currentData: head,
            fileExtension: ext
        ) {
            let wanted = min(Int64(expanded), maxArtworkHeadBytes)
            guard wanted > Int64(head.count),
                  let larger = try? await reader.read(offset: 0, length: wanted),
                  larger.count > head.count else { break }
            try Task.checkCancellation()
            head = larger
            metadata = await readMetadata(head, ext: ext)
        }
        try Task.checkCancellation()

        if let total = try? await reader.contentLength(), total > 0 {
            try Task.checkCancellation()
            if apeTailTagFormats.contains(ext) {
                let initialSize = min(
                    total,
                    Int64(RemoteMetadataReadPolicy.initialContainerTailByteCount)
                )
                if var tail = try? await reader.read(
                    offset: max(0, total - initialSize),
                    length: initialSize
                ) {
                    try Task.checkCancellation()
                    if let expanded = EmbeddedTagMetadataParser.expandedTailReadSize(
                        fileSize: total,
                        currentData: tail,
                        fileExtension: ext
                    ), expanded > tail.count,
                       let larger = try? await reader.read(
                        offset: max(0, total - Int64(expanded)),
                        length: Int64(expanded)
                       ) {
                        try Task.checkCancellation()
                        tail = larger
                    }
                    let tailMetadata = await FileMetadataReader.read(
                        from: head,
                        fileExtension: ext,
                        id3TailData: tail
                    )
                    metadata.fillMissing(from: tailMetadata)
                }
            } else if ext == "dsf",
                      let offset = EmbeddedTagMetadataParser.dsfMetadataOffset(in: head),
                      offset < total,
                      let tagHeader = try? await reader.read(offset: offset, length: 10),
                      !tagHeader.isEmpty {
                try Task.checkCancellation()
                let declared = EmbeddedTagMetadataParser.id3TagByteCount(in: tagHeader)
                    ?? tagHeader.count
                let tagLength = min(
                    Int64(RemoteMetadataReadPolicy.maximumHeadByteCount),
                    min(total - offset, Int64(declared))
                )
                let tagData: Data
                if tagLength > Int64(tagHeader.count) {
                    tagData = (try? await reader.read(
                        offset: offset,
                        length: tagLength
                    )) ?? tagHeader
                } else {
                    tagData = tagHeader
                }
                try Task.checkCancellation()
                let tagMetadata = await FileMetadataReader.read(
                    from: head,
                    fileExtension: ext,
                    id3TailData: tagData
                )
                metadata.fillMissing(from: tagMetadata)
            } else if id3ContainerTailFormats.contains(ext) {
                let tailSize = min(
                    total,
                    Int64(RemoteMetadataReadPolicy.initialContainerTailByteCount)
                )
                if let tail = try? await reader.read(
                    offset: max(0, total - tailSize),
                    length: tailSize
                ) {
                    try Task.checkCancellation()
                    let tailMetadata = await FileMetadataReader.read(
                        from: head,
                        fileExtension: ext,
                        id3TailData: tail
                    )
                    metadata.fillMissing(from: tailMetadata)
                }
            }
        }
        try Task.checkCancellation()

        if ((metadata.duration ?? 0) <= 0 || metadata.coverArtData == nil),
           tailFormats.contains(ext),
           let total = try? await reader.contentLength(),
           total > headBytes {
            for tailSize in RemoteMetadataReadPolicy.containerTailReadSizes(
                fileSize: total
            ) {
                try Task.checkCancellation()
                guard let tail = try? await reader.read(
                    offset: max(0, total - Int64(tailSize)),
                    length: Int64(tailSize)
                ), !tail.isEmpty else { continue }
                if let tailMetadata = await FileMetadataReader
                    .readISOBaseMediaMetadata(
                        head: head,
                        tail: tail,
                        fileExtension: ext
                    ) {
                    metadata.fillMissing(from: tailMetadata)
                    break
                }
            }
        }
        try Task.checkCancellation()

        var duration = metadata.duration ?? 0
        if ext == "mp3" {
            duration = RemoteMetadataReadPolicy.correctedMP3Duration(
                parsed: duration,
                fileSize: song.fileSize,
                bitRateKbps: metadata.bitRate,
                providedByteCount: head.count,
                leadingMetadataByteCount:
                    FileMetadataReader.id3TagByteCount(in: head) ?? 0
            )
        }
        let output = applying(metadata, to: song, duration: duration)
        try Task.checkCancellation()
        return try await attachAssets(
            song: output,
            embeddedLyrics: FileMetadataReader.parsedEmbeddedLyrics(from: metadata),
            embeddedCover: metadata.coverArtData,
            sidecars: sidecars,
            readerPool: readerPool
        )
    }

    static func applying(_ metadata: FileMetadataReader.Metadata, to song: Song, duration: Double) -> Song {
        var output = song
        // CUE identity fields come from the sheet. Container tags are often
        // album-level and must not overwrite every virtual track's title.
        if !song.isCueTrack {
            if let embeddedTitle = metadata.title?.trimmedNonEmpty,
               let title = MediaMetadataTextRepair.preferred(
                embedded: embeddedTitle,
                fromFileName: MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
            ) { output.title = title }
            if let album = metadata.albumTitle?.trimmedNonEmpty { output.albumTitle = album }
            if let artist = metadata.artist?.trimmedNonEmpty {
                output.artistName = artist
                output.sourceArtistNames = metadata.sourceArtistNames
            }
            output.albumArtistName = AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: metadata.albumArtist?.trimmedNonEmpty,
                trackArtistName: output.artistName
            )
            output.trackNumber = metadata.trackNumber ?? output.trackNumber
            output.discNumber = metadata.discNumber ?? output.discNumber
            output.year = metadata.year ?? output.year
            output.genre = metadata.genre ?? output.genre
        }
        output.bitRate = metadata.bitRate ?? output.bitRate
        output.sampleRate = metadata.sampleRate ?? output.sampleRate
        output.bitDepth = metadata.bitDepth ?? output.bitDepth
        output.replayGainTrackGain = metadata.replayGainTrackGain
            ?? output.replayGainTrackGain
        output.replayGainTrackPeak = metadata.replayGainTrackPeak
            ?? output.replayGainTrackPeak
        output.replayGainAlbumGain = metadata.replayGainAlbumGain
            ?? output.replayGainAlbumGain
        output.replayGainAlbumPeak = metadata.replayGainAlbumPeak
            ?? output.replayGainAlbumPeak

        if song.isCueTrack {
            if song.cueEndTime == nil, let start = song.cueStartTime,
               duration.isFinite, duration > start {
                output.duration = duration - start
            }
        } else if duration > 0 {
            output.duration = duration
        }
        MusicLibrary.fillDerivedIDs(&output)
        output = SongUserMetadataPolicy.preservingUserEdits(
            from: song,
            in: output
        )
        return output
    }

    private static func enrichSTRM(
        song: Song,
        sidecars: SidecarDirectoryIndex<TVDirEntry>,
        reader: any ByteRangeReader,
        readerPool: TVMetadataReaderPool
    ) async throws -> Song {
        let size = try await reader.contentLength()
        try Task.checkCancellation()
        guard size > 0,
              size <= Int64(STRMDescriptorParser.maximumByteCount) else {
            throw TVMetadataError.invalidDescriptor
        }
        let data = try await reader.read(offset: 0, length: size)
        try Task.checkCancellation()
        guard let descriptor = try? STRMDescriptorParser.parse(data) else {
            throw TVMetadataError.invalidDescriptor
        }
        var output = song
        output.title = descriptor.title ?? song.title
        output.artistName = descriptor.artist ?? song.artistName
        if descriptor.artist != nil { output.sourceArtistNames = nil }
        output.duration = descriptor.duration ?? song.duration
        output.fileFormat = descriptor.format
        output.fileSize = 0
        output.revision = STRMRevision.songRevision(
            wrapperRevision: song.revision,
            wrapperSize: size,
            wrapperModifiedDate: song.lastModified,
            contentRevision: descriptor.contentRevision
        )
        MusicLibrary.fillDerivedIDs(&output)
        output = SongUserMetadataPolicy.preservingUserEdits(
            from: song,
            in: output
        )
        return try await attachAssets(
            song: output,
            embeddedLyrics: nil,
            embeddedCover: nil,
            sidecars: sidecars,
            readerPool: readerPool
        )
    }

    private static func attachAssets(
        song: Song,
        embeddedLyrics: [LyricLine]?,
        embeddedCover: Data?,
        sidecars: SidecarDirectoryIndex<TVDirEntry>,
        readerPool: TVMetadataReaderPool
    ) async throws -> Song {
        try Task.checkCancellation()
        var output = song
        let basename = ((song.filePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        if output.mvPath == nil,
           let video = sidecars.sameNameMusicVideo(basename: basename) {
            output.mvPath = video.path
        }

        if song.userMetadataEditedAt == nil {
            var coverData = embeddedCover
            let cachedCoverName = MetadataAssetStore.shared
                .expectedCoverFileName(for: output.id)
            let hintedCover = output.coverArtFileName.flatMap { reference in
                reference == cachedCoverName
                    ? nil
                    : hintedSidecar(reference)
            }
            if coverData == nil,
               let cover = sidecars.sameNameCover(basename: basename)
                ?? sidecars.folderCover()
                ?? hintedCover {
                let size = try await boundedLength(
                    for: cover,
                    maximum: maximumSidecarArtworkBytes,
                    readerPool: readerPool
                )
                if size > 0 {
                    coverData = try? await readerPool.read(
                        path: cover.path,
                        size: cover.size,
                        offset: 0,
                        length: size
                    )
                }
            }
            try Task.checkCancellation()
            if let coverData,
               ArtworkImageCompatibility.isCompleteImage(coverData),
               !ArtworkImageCompatibility.hasRedundantJPEGSampling(coverData) {
                let store = MetadataAssetStore.shared
                if let albumID = output.albumID, !albumID.isEmpty {
                    let refresh = await readerPool.refreshesAlbumArtwork(albumID)
                    if refresh || !store.hasAlbumCover(forAlbumID: albumID) {
                        _ = await store.storeAlbumCover(coverData, forAlbumID: albumID)
                    }
                }
                try Task.checkCancellation()
                await store.cacheCover(coverData, forSongID: output.id)
                if await store.cachedCoverData(forSongID: output.id) != nil {
                    output.coverArtFileName = store.expectedCoverFileName(for: output.id)
                } else {
                    await readerPool.markIncomplete()
                }
            } else if coverData != nil {
                await readerPool.markIncomplete()
            }
        }

        let cachedLyricsName = MetadataAssetStore.shared
            .expectedLyricsFileName(for: output.id)
        let hintedLyrics = output.lyricsFileName.flatMap { reference in
            reference == cachedLyricsName
                ? nil
                : hintedSidecar(reference)
        }
        let albumLyrics = sidecars.sameNameLyrics(basename: basename)
        // CUE 分轨:扫描时按曲目挑出的那份歌词优先。整轨内嵌歌词和整轨同名歌词
        // 都是整张专辑的,给每一轨各缓存一份只会让每首都从第一首唱起;只有这一轨
        // 没有自己的歌词文件时才照旧用它们。
        let trackLyrics = song.isCueTrack
            ? hintedLyrics.flatMap {
                cueTrackLyricsDocument($0, song: song, albumLyrics: albumLyrics, sidecars: sidecars)
            }
            : nil
        var lyricLines: [LyricLine] = []
        if let trackLyrics {
            do {
                lyricLines = try await readLyricsSidecar(trackLyrics, readerPool: readerPool)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 分轨歌词读不到时按原来的顺序继续,不让整首的富集失败。
                lyricLines = []
            }
        }
        if lyricLines.isEmpty {
            lyricLines = embeddedLyrics ?? []
        }
        if lyricLines.isEmpty,
           let lyrics = albumLyrics ?? (trackLyrics == nil ? hintedLyrics : nil) {
            lyricLines = try await readLyricsSidecar(lyrics, readerPool: readerPool)
        }
        try Task.checkCancellation()
        if !lyricLines.isEmpty {
            let wrote = await MetadataAssetStore.shared.cacheLyrics(
                lyricLines, forSongID: output.id, force: false
            )
            if !wrote {
                guard let preserved = await MetadataAssetStore.shared.cachedLyrics(forSongID: output.id), !preserved.isEmpty else {
                    await readerPool.markIncomplete()
                    return output
                }
                lyricLines = preserved
            }
            output.lyricsFileName = MetadataAssetStore.shared
                .expectedLyricsFileName(for: output.id)
            output.lyricsText = lyricLines.map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .nilIfEmpty
        }
        return output
    }

    private static func readLyricsSidecar(
        _ lyrics: TVDirEntry,
        readerPool: TVMetadataReaderPool
    ) async throws -> [LyricLine] {
        let size = try await boundedLength(
            for: lyrics,
            maximum: maximumSidecarLyricsBytes,
            readerPool: readerPool
        )
        guard size > 0,
              let data = try? await readerPool.read(
                path: lyrics.path,
                size: lyrics.size,
                offset: 0,
                length: size
              ),
              let text = decodeText(data) else { return [] }
        return LyricsContentParser.parse(text)
    }

    /// 这一轨记下的歌词引用是不是它自己的分轨歌词。有目录清单时以清单为准:
    /// 必须还在目录里,而且不是整轨同名的那份;没有清单(续扫恢复出来的行)
    /// 时只能按名字判断。
    private static func cueTrackLyricsDocument(
        _ hinted: TVDirEntry,
        song: Song,
        albumLyrics: TVDirEntry?,
        sidecars: SidecarDirectoryIndex<TVDirEntry>
    ) -> TVDirEntry? {
        if sidecars.itemCount > 0 {
            guard let listed = sidecars.item(atPath: hinted.path),
                  listed.path != albumLyrics?.path else { return nil }
            return listed
        }
        return CueTrackLyricsSidecarPolicy.referencesTrackDocument(
            hinted.path,
            audioPath: song.filePath
        ) ? hinted : nil
    }

    private static func boundedLength(
        for item: TVDirEntry,
        maximum: Int64,
        readerPool: TVMetadataReaderPool
    ) async throws -> Int64 {
        let size: Int64
        if item.size > 0 {
            size = item.size
        } else {
            size = try await readerPool.contentLength(
                path: item.path,
                size: item.size
            )
        }
        guard size > 0, size <= maximum else { return 0 }
        return size
    }

    private static func hintedSidecar(_ reference: String) -> TVDirEntry? {
        guard !reference.isEmpty,
              !reference.contains("://"),
              SourceOwnedArtworkReference.resolve(reference) == nil else {
            return nil
        }
        return TVDirEntry(
            name: (reference as NSString).lastPathComponent,
            isDir: false,
            size: 0,
            path: reference
        )
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func readMetadata(
        _ data: Data,
        ext: String
    ) async -> FileMetadataReader.Metadata {
        await FileMetadataReader.read(from: data, fileExtension: ext)
    }
}

private actor TVMetadataRace {
    private var continuation: CheckedContinuation<TVMetadataEnrichmentResult, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var result: TVMetadataEnrichmentResult?

    func install(
        continuation: CheckedContinuation<TVMetadataEnrichmentResult, Never>,
        tasks: [Task<Void, Never>]
    ) {
        if let result {
            tasks.forEach { $0.cancel() }
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        self.tasks = tasks
    }

    func finish(_ result: TVMetadataEnrichmentResult) {
        guard self.result == nil else { return }
        self.result = result
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
