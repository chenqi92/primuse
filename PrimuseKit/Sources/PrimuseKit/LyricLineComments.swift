import CryptoKit
import Foundation
import Observation

public struct LyricLineCommentAnchor: Codable, Hashable, Sendable, Identifiable {
    public var text: String
    public var occurrence: Int
    public var voice: LyricVoice
    public var timestamp: TimeInterval

    public var id: String { "\(voice.rawValue):\(occurrence):\(Self.normalized(text))" }

    public init(text: String, occurrence: Int, voice: LyricVoice = .primary, timestamp: TimeInterval) {
        self.text = text
        self.occurrence = occurrence
        self.voice = voice
        self.timestamp = timestamp.isFinite ? max(0, timestamp) : 0
    }

    /// 原文与重复次数定位句子；解析器重建 id、时间轴重校准不会改变评论归属。
    public static func index(_ lines: [LyricLine]) -> [String: Self] {
        var counts: [String: Int] = [:]
        var anchors: [String: Self] = [:]
        func append(_ line: LyricLine) {
            let text = normalized(line.text)
            guard !text.isEmpty else { return }
            let key = "\(line.voice.rawValue):\(text)"
            let occurrence = counts[key, default: 0]
            counts[key] = occurrence + 1
            anchors[line.id] = Self(text: line.text, occurrence: occurrence, voice: line.voice, timestamp: line.timestamp)
        }
        for line in lines {
            append(line)
            for background in line.background ?? [] { append(background) }
        }
        return anchors
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct LyricLineComment: Codable, Equatable, Sendable, Identifiable {
    public var anchor: LyricLineCommentAnchor
    public var text: String
    public var updatedAt: Date
    public var deletedAt: Date? = nil
    public var id: String { anchor.id }

    public var isDeleted: Bool { deletedAt != nil }

    public static func winner(_ lhs: Self, _ rhs: Self) -> Self {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
        if lhs.isDeleted != rhs.isDeleted { return lhs.isDeleted ? lhs : rhs }
        // 同一时刻的离线编辑也必须在两台设备上收敛到同一结果。
        if lhs.text != rhs.text { return lhs.text > rhs.text ? lhs : rhs }
        if lhs.anchor.text != rhs.anchor.text { return lhs.anchor.text > rhs.anchor.text ? lhs : rhs }
        return lhs.anchor.timestamp >= rhs.anchor.timestamp ? lhs : rhs
    }
}

public struct LyricLineCommentSyncRecord: Codable, Equatable, Sendable, Identifiable {
    public static let prefix = "__lyric_line_comment__:"
    public var songID: String
    public var comment: LyricLineComment
    public var id: String {
        Self.prefix + SHA256.hash(data: Data((songID + "\0" + comment.id).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public extension Notification.Name {
    static let primuseLyricLineCommentsDidChange = Notification.Name("primuseLyricLineCommentsDidChange")
}

@MainActor
@Observable
public final class LyricLineCommentStore {
    public static let shared = LyricLineCommentStore(directory:
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Primuse/LyricComments", isDirectory: true)
    )
    public static let maximumLength = 2_000
    public private(set) var revision: UInt = 0
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var cache: [String: [String: LyricLineComment]] = [:]
    @ObservationIgnored private var cloudIndex: [String: (songID: String, anchorID: String)]?

    private struct Document: Codable {
        var songID: String
        var comments: [LyricLineComment]
        // nil 是尚未接入同步的旧文件，首次启动时逐条补传。
        var pendingUploadIDs: Set<String>? = nil
    }

    public init(directory: URL) { self.directory = directory }

    public func comment(songID: String, anchor: LyricLineCommentAnchor) throws -> LyricLineComment? {
        _ = revision
        let value = try records(songID: songID)[anchor.id]
        return value?.isDeleted == false ? value : nil
    }

    public func comments(songID: String) throws -> [LyricLineComment] {
        _ = revision
        return try records(songID: songID).values.filter { !$0.isDeleted }.sorted {
            if $0.anchor.timestamp != $1.anchor.timestamp { return $0.anchor.timestamp < $1.anchor.timestamp }
            return $0.id < $1.id
        }
    }

    public func save(songID: String, anchor: LyricLineCommentAnchor, text: String, now: Date = Date()) throws {
        // 每次修改先读持久副本；读取失败时不以空文档覆盖，多个窗口的编辑也不会抹掉别句。
        var document = try readDocument(songID: songID)
        var records = indexed(document.comments)
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
        let version = max(now, records[anchor.id]?.updatedAt.addingTimeInterval(0.001) ?? now)
        records[anchor.id] = LyricLineComment(anchor: anchor, text: body, updatedAt: version,
                                            deletedAt: body.isEmpty ? version : nil)
        document.pendingUploadIDs = pendingIDs(document).union([anchor.id])
        document.comments = Array(records.values)
        try write(document)
        NotificationCenter.default.post(name: .primuseLyricLineCommentsDidChange, object: self,
            userInfo: ["keys": [LyricLineCommentSyncRecord(songID: songID, comment: records[anchor.id]!).id]])
    }

    public func syncRecords(pendingOnly: Bool = false) throws -> [LyricLineCommentSyncRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { cloudIndex = [:]; return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var result: [LyricLineCommentSyncRecord] = []
        var index: [String: (songID: String, anchorID: String)] = [:]
        for file in files {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard file.lastPathComponent == fileURL(songID: document.songID).lastPathComponent else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let pending = pendingIDs(document)
            for comment in indexed(document.comments).values {
                let record = LyricLineCommentSyncRecord(songID: document.songID, comment: comment)
                index[record.id] = (record.songID, comment.id)
                if !pendingOnly || pending.contains(comment.id) { result.append(record) }
            }
        }
        cloudIndex = index
        return result.sorted { $0.id < $1.id }
    }

    public func syncRecord(for key: String) throws -> LyricLineCommentSyncRecord? {
        if cloudIndex == nil { _ = try syncRecords() }
        guard let entry = cloudIndex?[key],
              let comment = indexed(try readDocument(songID: entry.songID).comments)[entry.anchorID] else { return nil }
        return LyricLineCommentSyncRecord(songID: entry.songID, comment: comment)
    }

    /// 返回 true 表示本机有更新的编辑，需要把合并结果传回云端。
    @discardableResult
    public func applyRemote(_ remote: LyricLineCommentSyncRecord) throws -> Bool {
        var document = try readDocument(songID: remote.songID)
        var records = indexed(document.comments)
        let merged = records[remote.comment.id].map { LyricLineComment.winner($0, remote.comment) } ?? remote.comment
        records[merged.id] = merged
        var pending = pendingIDs(document)
        if merged == remote.comment { pending.remove(merged.id) } else { pending.insert(merged.id) }
        document.comments = Array(records.values)
        document.pendingUploadIDs = pending
        try write(document)
        return merged != remote.comment
    }

    public func acknowledgeUpload(_ sent: LyricLineCommentSyncRecord) throws {
        var document = try readDocument(songID: sent.songID)
        guard indexed(document.comments)[sent.comment.id] == sent.comment else { return }
        document.pendingUploadIDs = pendingIDs(document).subtracting([sent.comment.id])
        try write(document, publishes: false)
    }

    private func pendingIDs(_ document: Document) -> Set<String> {
        document.pendingUploadIDs ?? Set(document.comments.map(\.id))
    }

    private func indexed(_ comments: [LyricLineComment]) -> [String: LyricLineComment] {
        Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: LyricLineComment.winner)
    }

    private func write(_ document: Document, publishes: Bool = true) throws {
        var document = document
        document.comments.sort { $0.id < $1.id }
        let data = try JSONEncoder().encode(document)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(songID: document.songID), options: .atomic)
        cache[document.songID] = indexed(document.comments)
        for comment in document.comments {
            let record = LyricLineCommentSyncRecord(songID: document.songID, comment: comment)
            cloudIndex?[record.id] = (document.songID, comment.id)
        }
        if publishes { revision &+= 1 }
    }

    private func records(songID: String) throws -> [String: LyricLineComment] {
        if let cached = cache[songID] { return cached }
        let loaded = indexed(try readDocument(songID: songID).comments)
        cache[songID] = loaded
        return loaded
    }

    private func readDocument(songID: String) throws -> Document {
        let data: Data
        do { data = try Data(contentsOf: fileURL(songID: songID)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Document(songID: songID, comments: [], pendingUploadIDs: [])
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.songID == songID else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }

    private func fileURL(songID: String) -> URL {
        let name = SHA256.hash(data: Data(songID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
