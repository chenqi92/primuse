#if os(tvOS)
import AMSMB2
import CryptoKit
import Foundation
import PrimuseKit

/// 目录项(浏览/扫描用)。
struct TVDirEntry: Sendable, Identifiable, Hashable {
    let name: String
    let isDir: Bool
    let size: Int64
    let path: String      // share 内相对路径(与 SMBByteReader.resolve 一致,供播放复用)
    var id: String { path }
}

/// 目录列举器(浏览源的文件夹树)。先实现 SMB,其它协议后续补。
protocol TVDirectoryLister: Sendable {
    func list(_ path: String) async throws -> [TVDirEntry]
}

// MARK: - SMB 目录列举(AMSMB2)

actor TVSMBLister: TVDirectoryLister {
    private let serverURL: URL
    private let credential: URLCredential
    private let configuredShare: String
    private var manager: SMB2Manager?
    private var connectedShare: String?

    init?(source: MusicSource, credential cred: SourceCredential?) {
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let port = source.port ?? 445
        let hostPart = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        guard let url = URL(string: "smb://\(hostPart):\(port)") else { return nil }
        serverURL = url
        let user = (cred?.username ?? source.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = (cred?.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isGuest = user.isEmpty && pass.isEmpty
        credential = URLCredential(user: isGuest ? "guest" : user, password: pass, persistence: .forSession)
        configuredShare = (source.shareName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private func ensureManager() throws -> SMB2Manager {
        if let manager { return manager }
        guard let m = SMB2Manager(url: serverURL, credential: credential) else {
            throw TVScanError.connectFailed
        }
        manager = m
        return m
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        let (share, rel) = SMBByteReader.resolve(share: configuredShare, path: path)
        let m = try ensureManager()
        // 服务器根(未指定 share):列出可见共享当作一级目录。
        if share.isEmpty {
            let shares = try await m.listShares()
            return shares
                .filter { !$0.name.hasSuffix("$") && !$0.name.isEmpty }
                .map { TVDirEntry(name: $0.name, isDir: true, size: 0, path: "/\($0.name)") }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        if connectedShare != share {
            if connectedShare != nil { try? await m.disconnectShare() }
            try await m.connectShare(name: share)
            connectedShare = share
        }
        let items = try await m.contentsOfDirectory(atPath: rel)
        return items.compactMap { item -> TVDirEntry? in
            let name = item[.nameKey] as? String ?? ""
            guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = item[.fileSizeKey] as? Int64 ?? 0
            return TVDirEntry(name: name, isDir: isDir, size: size, path: Self.append(path, name))
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name) < ($1.isDir ? 0 : 1, $1.name) }
    }

    private static func append(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

enum TVScanError: Error { case connectFailed, unsupported }

// MARK: - 扫描服务(走查选中目录 → 路径式建 Song)

@MainActor
@Observable
final class TVSourceScanner {
    enum Phase: Equatable { case idle, browsing, scanning, done, failed(String) }

    var phase: Phase = .idle
    var indexed: Int = 0
    var currentFile: String = ""

    /// 构造源对应的目录列举器。目前仅 SMB;其它协议返回 nil(UI 据此提示)。
    static func makeLister(source: MusicSource, credential: SourceCredential?) -> TVDirectoryLister? {
        switch source.type {
        case .smb: return TVSMBLister(source: source, credential: credential)
        default: return nil
        }
    }

    var supportsScanning: Bool { false }   // 占位,实例方法在 makeLister 判定

    /// 浏览一层目录(给选目录页用)。
    func browse(lister: TVDirectoryLister, path: String) async -> [TVDirEntry] {
        (try? await lister.list(path)) ?? []
    }

    /// 走查选中目录建库:先路径骨架(快),再逐文件读真实 tag/时长/封面/歌词(慢)。
    /// 返回 nil 表示失败(phase 已置 .failed)。`credential` 用于读文件头补元数据。
    func scan(source: MusicSource, lister: TVDirectoryLister, dirs: [String],
              credential: SourceCredential?) async -> [Song]? {
        phase = .scanning
        indexed = 0
        currentFile = ""
        // (骨架 Song, 同级文件列表) —— 同级文件给 enrich 找同名 .lrc / cover.jpg。
        var collected: [(song: Song, siblings: [TVDirEntry])] = []
        var seen = Set<String>()
        do {
            for dir in dirs {
                try await collect(lister: lister, path: dir, source: source, into: &collected, seen: &seen)
            }
        } catch {
            phase = .failed((error as? TVScanError) == .connectFailed ? "连接失败,请检查地址/凭据" : error.localizedDescription)
            return nil
        }
        let songs = await enrichAll(collected, source: source, credential: credential)
        indexed = songs.count
        phase = .done
        return songs
    }

    /// 递归遍历:收集每首歌的路径骨架 + 其所在目录的同级文件(供找歌词/封面)。
    private func collect(lister: TVDirectoryLister, path: String, source: MusicSource,
                         into collected: inout [(song: Song, siblings: [TVDirEntry])],
                         seen: inout Set<String>) async throws {
        let entries = try await lister.list(path)
        let files = entries.filter { !$0.isDir }
        for e in entries {
            if e.isDir {
                try await collect(lister: lister, path: e.path, source: source, into: &collected, seen: &seen)
            } else {
                let ext = (e.name as NSString).pathExtension.lowercased()
                guard PrimuseConstants.supportedAudioExtensions.contains(ext) else { continue }
                guard seen.insert(e.path).inserted else { continue }
                collected.append((Self.makeSong(entry: e, source: source), files))
                indexed = collected.count
                currentFile = e.path
            }
        }
    }

    /// 逐文件补真实元数据(有限并发,默认 4)。失败的文件保留路径骨架,不阻断。
    private func enrichAll(_ items: [(song: Song, siblings: [TVDirEntry])],
                           source: MusicSource, credential: SourceCredential?) async -> [Song] {
        var result: [Song] = []
        result.reserveCapacity(items.count)
        let chunk = 4
        var i = 0
        while i < items.count {
            let slice = Array(items[i..<min(i + chunk, items.count)])
            let enriched: [Song] = await withTaskGroup(of: (Int, Song).self) { group in
                for (j, it) in slice.enumerated() {
                    group.addTask {
                        (j, await TVMetadataEnricher.enrich(song: it.song, source: source,
                                                            credential: credential, siblings: it.siblings))
                    }
                }
                var acc = [Song?](repeating: nil, count: slice.count)
                for await (j, s) in group { acc[j] = s }
                return acc.compactMap { $0 }
            }
            result.append(contentsOf: enriched)
            i += chunk
            currentFile = enriched.last?.filePath ?? currentFile
        }
        return result
    }

    /// 路径式建 Song(Phase A):标题=文件名,专辑=父文件夹,艺术家=祖父文件夹。
    /// id / albumID / artistID 用与手机端 LibraryScanner 完全一致的 SHA256 派生,保证可合并去重。
    static func makeSong(entry e: TVDirEntry, source: MusicSource) -> Song {
        let comps = e.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let rawName = (e.name as NSString).deletingPathExtension
        var title = Self.stripTrackNumber(rawName)
        let album = comps.count >= 2 ? comps[comps.count - 2] : nil
        var artist = comps.count >= 3 ? comps[comps.count - 3] : nil
        // 扁平文件夹(没有 艺术家/专辑 层级)时,尝试从文件名 "艺术家 - 标题" 解析。
        if artist == nil || artist == album, let dash = rawName.range(of: " - ") {
            let a = String(rawName[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let t = String(rawName[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !t.isEmpty { artist = a; title = Self.stripTrackNumber(t) }
        }
        let format = AudioFormat.from(fileExtension: (e.name as NSString).pathExtension) ?? .mp3
        let artistID = artist.map { sha256($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
        let albumID: String? = (album != nil && artist != nil)
            ? sha256("\(artist!.lowercased()):\(album!.lowercased())") : nil
        return Song(
            id: sha256("\(source.id):\(e.path)"),
            title: title.isEmpty ? e.name : title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: album,
            artistName: artist,
            fileFormat: format,
            filePath: e.path,
            sourceID: source.id,
            fileSize: e.size
        )
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 去掉文件名开头的音轨号(1-3 位数字 + 可选分隔符):"03 七里香" → "七里香"。
    /// 4 位以上数字(如年份 1989)不当音轨号。
    static func stripTrackNumber(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #"^\d{1,3}\s*[.\-_]?\s*"#, options: .regularExpression) {
            let rest = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }
}
#endif
