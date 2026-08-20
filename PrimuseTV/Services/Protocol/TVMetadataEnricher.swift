#if os(tvOS)
import Foundation
import PrimuseKit

/// 给 TV 本机扫出来的「路径骨架」Song 补真实元数据 —— 时长 / 专辑 / 封面 / 歌词。
///
/// 复用手机端同一套读 tag 的代码(`FileMetadataReader` 已编进 PrimuseTV target),
/// 经 `SMBByteReader` 按 byte-range 只读文件头(不整文件下载),直接在内存中交给
/// `FileMetadataReader.read`。MP3 截断头时长不准时,用目录列举已知的真实 fileSize
/// 反推(抄手机端 `MetadataBackfillService.correctedDuration` 同款逻辑)。封面写进
/// `MetadataAssetStore` 的 album 缓存,歌词(嵌入 USLT / 同目录 .lrc)写进 song 缓存。
enum TVMetadataEnricher {
    static let headBytes: Int64 = 1 << 20          // 1MB:足够 FLAC STREAMINFO+注释、ID3、给 MP3 估码率
    static let maxArtworkHeadBytes: Int64 = 4 << 20 // ID3 大封面再扩到 4MB

    /// 容器格式的元数据(尤其 duration)可能在文件尾部,需 head+tail 拼读。
    private static let tailFormats: Set<String> = ["m4a", "mp4", "m4b", "alac", "aac", "m4v", "mov"]

    /// 读真实 tag 并合并进 `song`,带单文件超时(默认 25s)。任何失败 / 超时都原样返回
    /// 路径骨架,绝不让某个卡死的文件(SMB 读挂起 / AVAsset 解析卡住)拖死整次扫描。
    /// `siblings` = 该文件所在目录的同级文件项(用于找同名 .lrc 歌词、cover.jpg)。
    static func enrich(song: Song, source: MusicSource, credential: SourceCredential?,
                       siblings: [TVDirEntry], timeoutSeconds: UInt64 = 25) async -> Song {
        let once = OnceGuard()
        return await withCheckedContinuation { (cont: CheckedContinuation<Song, Never>) in
            // 两个非结构化任务赛跑:谁先到先 resume。读取卡死时由超时任务兜底返回骨架,
            // 卡死的读取任务自行泄漏(AMSMB2/AVAsset 各自最终超时收尾),不阻塞扫描推进。
            Task {
                let result = await enrichCore(song: song, source: source, credential: credential, siblings: siblings)
                if await once.claim() { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if await once.claim() { cont.resume(returning: song) }
            }
        }
    }

    /// 实际读取逻辑(被带超时的 `enrich` 包裹)。
    private static func enrichCore(song: Song, source: MusicSource,
                                   credential: SourceCredential?, siblings: [TVDirEntry]) async -> Song {
        guard let reader = TVPlaybackCoordinator.makeDirectReader(
            source: source,
            song: song,
            credential: credential
        ) else {
            return song
        }
        if song.isStreamDescriptor {
            return await enrichSTRM(
                song: song,
                source: source,
                credential: credential,
                siblings: siblings,
                reader: reader
            )
        }
        let ext = song.fileFormat.rawValue.lowercased()
        guard var head = try? await reader.read(offset: 0, length: headBytes), !head.isEmpty else {
            // 头都读不到:仍尝试同目录 .lrc 歌词(轻量),其它保持原样。
            return await attachSidecarLyrics(song: song, source: source, credential: credential,
                                             siblings: siblings, embedded: nil)
        }
        var meta = await readMetadata(head, ext: ext)

        // ID3 内嵌封面比 1MB 头还大 → 按 tag 声明的长度扩读再解。
        if meta.coverArtData == nil,
           let declared = FileMetadataReader.id3TagByteCount(in: head),
           declared > head.count {
            let expanded = RemoteMetadataReadPolicy.expandedReadSize(
                fileSize: song.fileSize,
                currentByteCount: head.count,
                declaredID3ByteCount: declared,
                metadataInsufficient: false
            ) ?? head.count
            let want = min(Int64(expanded), maxArtworkHeadBytes)
            if want > Int64(head.count), let bigger = try? await reader.read(offset: 0, length: want), !bigger.isEmpty {
                head = bigger
                meta = await readMetadata(head, ext: ext)
            }
        }
        // m4a/mp4:moov 在尾部时逐步扩读,只提取完整 ftyp+moov 再交给
        // AVFoundation。任意 head+tail 直接拼接会留下截断 mdat,不是有效容器。
        if (meta.duration ?? 0) <= 0, tailFormats.contains(ext),
           let total = try? await reader.contentLength(), total > headBytes {
            for tailSize in RemoteMetadataReadPolicy.containerTailReadSizes(fileSize: total) {
                guard let tail = try? await reader.read(
                    offset: max(0, total - Int64(tailSize)),
                    length: Int64(tailSize)
                ), !tail.isEmpty else {
                    continue
                }
                if let tailMetadata = await FileMetadataReader.readISOBaseMediaMetadata(
                    head: head,
                    tail: tail,
                    fileExtension: ext
                ) {
                    meta.fillMissing(from: tailMetadata)
                    if (meta.duration ?? 0) > 0 { break }
                }
            }
        }

        var out = song
        if let t = meta.title?.trimmedNonEmpty { out.title = t }
        if let al = meta.albumTitle?.trimmedNonEmpty { out.albumTitle = al }
        if let ar = meta.artist?.trimmedNonEmpty { out.artistName = ar }
        out.albumArtistName = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: meta.albumArtist?.trimmedNonEmpty ?? out.albumArtistName,
            trackArtistName: out.artistName
        )
        out.bitRate = meta.bitRate ?? out.bitRate
        out.sampleRate = meta.sampleRate ?? out.sampleRate
        out.bitDepth = meta.bitDepth ?? out.bitDepth
        out.year = meta.year ?? out.year
        out.genre = meta.genre ?? out.genre
        out.trackNumber = meta.trackNumber ?? out.trackNumber
        out.discNumber = meta.discNumber ?? out.discNumber
        out.replayGainTrackGain = meta.replayGainTrackGain ?? out.replayGainTrackGain
        out.replayGainTrackPeak = meta.replayGainTrackPeak ?? out.replayGainTrackPeak
        out.replayGainAlbumGain = meta.replayGainAlbumGain ?? out.replayGainAlbumGain
        out.replayGainAlbumPeak = meta.replayGainAlbumPeak ?? out.replayGainAlbumPeak

        var duration = meta.duration ?? 0
        if ext == "mp3" {
            duration = RemoteMetadataReadPolicy.correctedMP3Duration(
                parsed: duration,
                fileSize: song.fileSize,
                bitRateKbps: meta.bitRate,
                providedByteCount: head.count,
                leadingMetadataByteCount: FileMetadataReader.id3TagByteCount(in: head) ?? 0
            )
        }
        if duration > 0 { out.duration = duration }

        // 用真实 album/artist 重算派生 ID(与 MusicLibrary 一致),拿到 UI/封面缓存用的 albumID。
        MusicLibrary.fillDerivedIDs(&out)

        // 内嵌封面 → 写 album 封面缓存(TVArtworkView 会优先读它)。同专辑多首只写一次。
        if let cover = meta.coverArtData, let albumID = out.albumID, !albumID.isEmpty {
            let store = MetadataAssetStore.shared
            if !store.hasAlbumCover(forAlbumID: albumID) {
                _ = await store.storeAlbumCover(cover, forAlbumID: albumID)
            }
            await store.cacheCover(cover, forSongID: out.id)
            out.coverArtFileName = store.expectedCoverFileName(for: out.id)
        }

        return await attachSidecarLyrics(song: out, source: source, credential: credential,
                                         siblings: siblings, embedded: meta.lyricsText)
    }

    private static func enrichSTRM(
        song: Song,
        source: MusicSource,
        credential: SourceCredential?,
        siblings: [TVDirEntry],
        reader: ByteRangeReader
    ) async -> Song {
        guard let size = try? await reader.contentLength(),
              size > 0,
              size <= Int64(STRMDescriptorParser.maximumByteCount),
              let data = try? await reader.read(offset: 0, length: size),
              let descriptor = try? STRMDescriptorParser.parse(data) else {
            return song
        }
        var out = song
        out.title = descriptor.title ?? song.title
        out.artistName = descriptor.artist ?? song.artistName
        out.duration = descriptor.duration ?? song.duration
        out.fileFormat = descriptor.format
        out.fileSize = 0
        out.revision = STRMRevision.songRevision(
            wrapperRevision: nil,
            wrapperSize: size,
            wrapperModifiedDate: nil,
            contentRevision: descriptor.contentRevision
        )
        MusicLibrary.fillDerivedIDs(&out)
        return await attachSidecarLyrics(
            song: out,
            source: source,
            credential: credential,
            siblings: siblings,
            embedded: nil
        )
    }

    // MARK: 歌词:嵌入 USLT 优先,否则同目录同名 .lrc

    private static func attachSidecarLyrics(song: Song, source: MusicSource, credential: SourceCredential?,
                                            siblings: [TVDirEntry], embedded: String?) async -> Song {
        var out = song
        let base = (song.filePath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension.lowercased()
        if out.mvPath == nil,
           let mv = siblings.first(where: { !$0.isDir
               && PrimuseConstants.supportedMusicVideoExtensions.contains(($0.name as NSString).pathExtension.lowercased())
               && ($0.name as NSString).deletingPathExtension.lowercased() == stem }) {
            out.mvPath = mv.path
        }

        var lines: [LyricLine] = []
        if let embedded, !embedded.isEmpty {
            lines = LyricsParser.parse(embedded)
        }
        if lines.isEmpty {
            if let lrc = siblings.first(where: { !$0.isDir
                && ($0.name as NSString).pathExtension.lowercased() == "lrc"
                && ($0.name as NSString).deletingPathExtension.lowercased() == stem }),
               let reader = TVPlaybackCoordinator.makeDirectReader(
                   source: source,
                   filePath: lrc.path,
                   credential: credential
               ),
               let size = try? await reader.contentLength(), size > 0, size < 512 * 1024,
               let data = try? await reader.read(offset: 0, length: size),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                lines = LyricsParser.parse(text)
            }
        }
        guard !lines.isEmpty else { return out }
        _ = await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: song.id, force: false)
        out.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
        out.lyricsText = lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n").nilIfEmpty
        return out
    }

    // MARK: 工具

    private static func readMetadata(_ data: Data, ext: String) async -> FileMetadataReader.Metadata {
        await FileMetadataReader.read(from: data, fileExtension: ext)
    }
}

/// 单次 resume 守卫:赛跑的两个任务里只有第一个能 resume continuation。
private actor OnceGuard {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
