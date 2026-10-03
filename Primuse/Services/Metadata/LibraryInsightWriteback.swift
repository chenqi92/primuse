import Foundation
import PrimuseKit

/// 把专辑 / 艺人简介写回音乐源,也把音乐源上已有的简介读回来:
/// - 文件类音乐源:专辑文件夹的 `album.nfo`、艺人文件夹的 `artist.nfo`;
/// - Jellyfin、Emby、Plex:专辑与艺人的「简介」字段;
/// - 开了开关时,专辑简介再写进每首歌的「注释」(整首下载、改写、替换、回读)。
/// 判断不了该写到哪儿就不写;读不懂的 nfo 不覆盖。
@MainActor
enum LibraryInsightWriteback {
    struct Report: Equatable, Sendable {
        var written: [String] = []
        var failed: [String] = []

        var isEmpty: Bool { written.isEmpty && failed.isEmpty }
    }

    /// 本次运行里已经去音乐源找过简介的专辑 / 艺人,不再重复读。
    private static var importAttemptedIDs: Set<String> = []

    // MARK: - 写回

    /// 简介保存、生成或删除之后调用。`songs` 是这张专辑 / 这位艺人在曲库里的歌。
    static func write(
        _ record: LibraryInsightRecord?,
        subject: LibraryInsightSubject,
        songs: [Song],
        library: MusicLibrary,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> Report {
        var report = Report()
        let writesFiles = LibraryInsightWritebackPolicy.writesFiles()
        let embedsComment = subject.kind == .album && LibraryInsightWritebackPolicy.embedsComment()
        guard writesFiles || embedsComment else { return report }
        let live = record.flatMap { $0.isDeleted ? nil : $0 }
        let summary = live?.summary ?? ""
        let tags = live?.tags ?? []

        for (sourceID, sourceSongs) in Dictionary(grouping: playable(songs), by: \.sourceID)
            .sorted(by: { $0.key < $1.key }) {
            guard let source = sourcesStore.source(id: sourceID), let first = sourceSongs.first else { continue }
            if writesFiles {
                if Self.isMediaServer(source.type) {
                    // 删掉简介时不去清服务器上的:那里原本的简介可能是服务器自己抓来的。
                    if live?.hasContent == true {
                        await writeServerOverview(
                            summary: summary, tags: tags, subject: subject, song: first,
                            source: source, sourceManager: sourceManager, report: &report
                        )
                    }
                } else {
                    await writeNFO(
                        summary: summary, tags: tags, subject: subject, songs: sourceSongs,
                        source: source, library: library, sourceManager: sourceManager, report: &report
                    )
                }
            }
            if embedsComment, !summary.isEmpty {
                await embedComment(
                    summary, in: sourceSongs, source: source,
                    library: library, sourceManager: sourceManager, report: &report
                )
            }
        }
        if !report.isEmpty {
            plog("📝 Library insight writeback kind=\(subject.kind.rawValue) written=\(report.written.count) failed=\(report.failed.count)")
        }
        return report
    }

    private static func writeServerOverview(
        summary: String,
        tags: [String],
        subject: LibraryInsightSubject,
        song: Song,
        source: MusicSource,
        sourceManager: SourceManager,
        report: inout Report
    ) async {
        do {
            guard let connector = try await sourceManager.connectorForSong(song) as? any LibraryInsightServerConnector else {
                return
            }
            try await connector.writeCollectionOverview(summary, tags: tags, collection: subject.kind, for: song)
            report.written.append(source.name)
        } catch {
            plog("⚠️ Library insight server write failed source=\(source.type.rawValue): \(error.localizedDescription)")
            report.failed.append(source.name)
        }
    }

    private static func writeNFO(
        summary: String,
        tags: [String],
        subject: LibraryInsightSubject,
        songs: [Song],
        source: MusicSource,
        library: MusicLibrary,
        sourceManager: SourceManager,
        report: inout Report
    ) async {
        guard let first = songs.first,
              let folder = folder(for: subject, songs: songs, library: library) else { return }
        let fileName = LibraryInsightNFO.fileName(for: subject.kind)
        let path = LibraryInsightFolderPolicy.filePath(in: folder, kind: subject.kind)
        do {
            let connector = try await sourceManager.sidecarWriteConnector(for: first)
            guard connector.supportsSidecarWriting else { return }
            let existing = try await readText(at: path, in: folder, using: connector)
            // 没有文件、也没东西可写(删除简介)时,不为它新建一份空 nfo。
            if existing == nil, summary.isEmpty, tags.isEmpty { return }
            guard let document = LibraryInsightNFO.updatedDocument(
                existing: existing?.text,
                kind: subject.kind,
                title: subject.albumTitle,
                artist: subject.artistName,
                summary: summary,
                tags: tags
            ) else {
                plog("ℹ️ Library insight: \(fileName) exists but is not a \(subject.kind.rawValue) nfo; left untouched")
                report.failed.append(fileName)
                return
            }
            guard document != existing?.text else { return }
            let data = Data(document.utf8)
            try await connector.writeFile(data: data, to: path, priority: .background)
            try await connector.verifySidecarWrite(data: data, at: path)
            report.written.append(fileName)
        } catch {
            plog("⚠️ Library insight nfo write failed source=\(source.type.rawValue): \(error.localizedDescription)")
            report.failed.append(fileName)
        }
    }

    private static func embedComment(
        _ summary: String,
        in songs: [Song],
        source: MusicSource,
        library: MusicLibrary,
        sourceManager: SourceManager,
        report: inout Report
    ) async {
        var written = 0
        var failed = 0
        for song in songs {
            guard await sourceManager.supportsEmbeddedTagWrite(for: song) else { continue }
            // 冲突判断按库里记的文件身份做。
            var target = song
            if let latest = library.song(id: song.id) {
                target.filePath = latest.filePath
                target.fileSize = latest.fileSize
                target.lastModified = latest.lastModified
                target.revision = latest.revision
            }
            do {
                let updated = try await sourceManager.writeEmbeddedComment(.set(summary), for: target)
                library.flushPendingAssetReferencePatches()
                if var latest = library.song(id: song.id) {
                    latest.filePath = updated.filePath
                    latest.fileSize = updated.fileSize
                    latest.lastModified = updated.lastModified
                    latest.revision = updated.revision
                    library.replaceSong(latest)
                }
                written += 1
            } catch {
                plog("⚠️ Library insight comment write failed songID=\(song.id): \(error.localizedDescription)")
                failed += 1
            }
        }
        let label = String(format: String(localized: "library_insight_writeback_comments_format"), written)
        if written > 0 { report.written.append(label) }
        if failed > 0 {
            report.failed.append(String(format: String(localized: "library_insight_writeback_comments_format"), failed))
        }
    }

    // MARK: - 读回

    /// 曲库里还没有这张专辑 / 这位艺人的简介(也没被删过)时,去音乐源找:
    /// 文件夹里的 nfo,或服务器上的简介。找到就存成一份「来自 …」的简介。
    static func importIfAvailable(
        subject: LibraryInsightSubject,
        songs: [Song],
        library: MusicLibrary,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async {
        let id = LibraryInsightStore.shared.recordID(for: subject)
        guard library.storedLibraryInsightRecord(id: id) == nil,
              importAttemptedIDs.insert(id).inserted else { return }
        for (sourceID, sourceSongs) in Dictionary(grouping: playable(songs), by: \.sourceID)
            .sorted(by: { $0.key < $1.key }) {
            guard let source = sourcesStore.source(id: sourceID), let first = sourceSongs.first else { continue }
            var found: (summary: String, tags: [String], label: String)?
            if isMediaServer(source.type) {
                if let connector = try? await sourceManager.connectorForSong(first) as? any LibraryInsightServerConnector,
                   let overview = try? await connector.collectionOverview(subject.kind, for: first) {
                    let summary = LibraryInsightEditing.normalizedSummary(
                        LibraryInsightNFO.plainText(fromMarkup: overview)
                    )
                    if !summary.isEmpty { found = (summary, [], source.name) }
                }
            } else if let folder = folder(for: subject, songs: sourceSongs, library: library),
                      let connector = try? await sourceManager.auxiliaryConnector(for: first) {
                let path = LibraryInsightFolderPolicy.filePath(in: folder, kind: subject.kind)
                if let existing = try? await readText(at: path, in: folder, using: connector),
                   let read = LibraryInsightNFO.read(existing.text, kind: subject.kind) {
                    found = (read.summary, read.tags, LibraryInsightNFO.fileName(for: subject.kind))
                }
            }
            guard let found else { continue }
            // 读的这一会儿用户可能已经自己写了一份。
            guard library.storedLibraryInsightRecord(id: id) == nil,
                  let record = LibraryInsightEditing.recordFromImport(
                    summary: found.summary,
                    tags: found.tags,
                    subject: subject,
                    id: id,
                    sourceLabel: found.label,
                    now: Date()
                  ) else { return }
            plog("📥 Library insight imported kind=\(subject.kind.rawValue) from=\(isMediaServer(source.type) ? "server" : "nfo")")
            library.saveLibraryInsightRecord(record)
            return
        }
    }

    // MARK: - Helpers

    static func isMediaServer(_ type: MusicSourceType) -> Bool {
        type == .jellyfin || type == .emby || type == .plex
    }

    /// 只看真的文件:流地址与 CUE 分轨的虚拟路径不算。
    private static func playable(_ songs: [Song]) -> [Song] {
        songs.filter { !$0.isStreamDescriptor && !$0.filePath.isEmpty }
    }

    /// 这张专辑 / 这位艺人在这个音乐源上的文件夹;判断不了返回 nil。
    private static func folder(
        for subject: LibraryInsightSubject,
        songs: [Song],
        library: MusicLibrary
    ) -> String? {
        switch subject.kind {
        case .album:
            let paths = songs.map(\.filePath)
            guard let candidate = LibraryInsightFolderPolicy.candidateAlbumFolder(trackPaths: paths),
                  let sourceID = songs.first?.sourceID else { return nil }
            let albumIDs = Set(songs.compactMap(\.albumID))
            let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
            let others = library.visibleSongs.lazy
                .filter { $0.sourceID == sourceID && $0.filePath.hasPrefix(prefix) }
                .filter { song in song.albumID.map { !albumIDs.contains($0) } ?? true }
                .map(\.filePath)
            return LibraryInsightFolderPolicy.albumFolder(trackPaths: paths, otherAlbumTrackPaths: Array(others))
        case .artist:
            let albumFolders = Dictionary(grouping: songs, by: { $0.albumID ?? $0.albumTitle ?? "" })
                .values
                .compactMap { LibraryInsightFolderPolicy.candidateAlbumFolder(trackPaths: $0.map(\.filePath)) }
            return LibraryInsightFolderPolicy.artistFolder(albumFolders: albumFolders, artistName: subject.artistName)
        }
    }

    /// 读文件夹里的 nfo;不存在返回 nil。读不了(太大、读失败、不是 UTF-8)时抛错,调用方不覆盖它。
    private static func readText(
        at path: String,
        in folder: String,
        using connector: any MusicSourceConnector
    ) async throws -> (text: String, size: Int64)? {
        let name = (path as NSString).lastPathComponent
        guard let item = try await connector.listFiles(at: folder).first(where: {
            !$0.isDirectory && ($0.path == path || $0.name.caseInsensitiveCompare(name) == .orderedSame)
        }) else { return nil }
        guard item.size <= Int64(LibraryInsightNFO.maximumReadBytes) else {
            throw SourceError.connectionFailed("nfo too large")
        }
        let data = try await connector.fetchRange(
            path: item.path,
            offset: 0,
            length: max(item.size, 1),
            priority: .background
        )
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SourceError.connectionFailed("nfo is not UTF-8")
        }
        return (text, item.size)
    }
}
