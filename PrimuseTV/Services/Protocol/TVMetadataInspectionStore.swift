#if os(tvOS)
import Foundation
import PrimuseKit

enum TVPlaybackMetadataPolicy {
    static func supports(_ type: MusicSourceType) -> Bool {
        [.local, .smb, .nfs, .ftp, .webdav, .oneDrive, .dropbox].contains(type)
    }
}

actor TVMetadataInspectionStore {
    static let shared = TVMetadataInspectionStore()
    static let parserVersion = 1

    private struct Entry: Codable {
        let metadata: String
        let sidecars: String?
    }
    private let url: URL
    private var entries: [String: Entry]
    private var flushTask: Task<Void, Never>?
    /// 上次落盘之后有没有新记录。扫描收尾和进后台都会显式 flush,没新东西就不重写整份文件。
    private var isDirty = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse/tv-metadata-inspections.json")
        entries = (try? Data(contentsOf: self.url))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func isCurrent(_ song: Song, sidecars: SidecarDirectoryIndex<TVDirEntry>? = nil) async -> Bool {
        guard let entry = entries[key(song)], entry.metadata == signature(song) else { return false }
        let assets = MetadataAssetStore.shared
        if song.coverArtFileName == assets.expectedCoverFileName(for: song.id),
           await assets.cachedCoverData(forSongID: song.id) == nil { return false }
        if song.lyricsFileName == assets.expectedLyricsFileName(for: song.id),
           await assets.cachedLyrics(forSongID: song.id) == nil { return false }
        guard let sidecars else { return true }
        return entry.sidecars == Self.sidecarSignature(song, sidecars: sidecars)
    }

    func isCurrent(
        _ existing: Song,
        or reconciled: Song,
        sidecars: SidecarDirectoryIndex<TVDirEntry>? = nil
    ) async -> Bool {
        if await isCurrent(existing, sidecars: sidecars) { return true }
        return await isCurrent(reconciled, sidecars: sidecars)
    }

    func record(_ song: Song, sidecars: SidecarDirectoryIndex<TVDirEntry>? = nil, complete: Bool) {
        guard complete else { return }
        entries[key(song)] = Entry(metadata: signature(song), sidecars: sidecars.map { Self.sidecarSignature(song, sidecars: $0) })
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.flush()
        }
    }

    /// 定时器到点、扫描收尾(含取消)与 App 进后台时调用。电视切走后进程很快被挂起,
    /// 不等定时器的话最后几秒读过的歌下次会重读一遍。
    func flush() {
        flushTask?.cancel()
        defer { flushTask = nil }
        guard isDirty else { return }
        isDirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func key(_ song: Song) -> String {
        TVScanPipelinePolicy.hash32(song.sourceID + "\u{0}" + song.id)
    }

    private func signature(_ song: Song) -> String {
        // Include the inspected values as well as byte identity: a crash before
        // the library write, snapshot replacement, or a newer reader must retry.
        var inspected = song
        inspected.albumID = nil
        inspected.artistID = nil
        inspected.titlePinyin = nil
        inspected.artistPinyin = nil
        inspected.albumPinyin = nil
        inspected.dateAdded = .distantPast
        inspected.serverPlayCount = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(inspected)) ?? Data()
        return TVScanPipelinePolicy.hash32("\(Self.parserVersion):" + data.base64EncodedString())
    }

    private static func sidecarSignature(_ song: Song, sidecars: SidecarDirectoryIndex<TVDirEntry>) -> String {
        let basename = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        // CUE 虚拟分轨的歌词可能是按曲目分开的文件,名字和整轨不同名;把它们也
        // 算进来,后来补进目录的分轨歌词下次扫描才会被读到。没有这类文件的目录
        // 签名和以前完全一样,不会因为升级把所有 CUE 分轨重读一遍。
        return sidecars.snapshotFingerprint(
            selectedPaths: [
                sidecars.sameNameCover(basename: basename)?.path ?? sidecars.folderCover()?.path,
                sidecars.sameNameLyrics(basename: basename)?.path,
                sidecars.sameNameMusicVideo(basename: basename)?.path,
            ],
            includingCueTrackLyrics: song.isCueTrack
        ) ?? ""
    }
}

actor TVMetadataReadAudit {
    var failures = 0
    /// 这一段窗口里的远端请求统计,扫描器每读完一批歌取走一次打日志。
    private var window = TVScanReadStatistics()

    func failed() { failures += 1 }

    func requestCompleted(bytes: Int, seconds: Double) {
        window.recordRequest(bytes: bytes, seconds: seconds)
    }

    func requestFailed(_ error: any Error, seconds: Double) {
        failures += 1
        guard !(error is CancellationError) else { return }
        window.recordFailure(timedOut: (error as? URLError)?.code == .timedOut, seconds: seconds)
    }

    func takeWindow() -> TVScanReadStatistics {
        defer { window = TVScanReadStatistics() }
        return window
    }
}

struct TVAuditedMetadataReader: ByteRangeReader {
    let reader: any ByteRangeReader
    let audit: TVMetadataReadAudit

    func contentLength() async throws -> Int64 {
        do { return try await reader.contentLength() }
        catch { await audit.failed(); throw error }
    }
    func read(offset: Int64, length: Int64) async throws -> Data {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let data = try await reader.read(offset: offset, length: length)
            await audit.requestCompleted(bytes: data.count,
                                         seconds: ProcessInfo.processInfo.systemUptime - startedAt)
            return data
        } catch {
            await audit.requestFailed(error, seconds: ProcessInfo.processInfo.systemUptime - startedAt)
            throw error
        }
    }
    func close() async { await reader.close() }
}
#endif
