import CryptoKit
import Foundation

/// 各个源的已提交同步状态,每个源各存各的文件,放在 `source-sync-states/` 目录里:
/// - `<stem>.state.json`:除索引以外的全部字段(仍由 `SourceSyncState` 的 Codable 决定,
///   以后加的字段照常进去),外加它引用的索引文件名、行数与 SHA-256;
/// - `<stem>.<UUID>.index`:紧凑索引的二进制(`SourceSyncIndex.writeBinary`),
///   索引为空时没有这个文件。
/// `<stem>` 是源 ID 的 SHA-256 前 32 位十六进制:源 ID 不一定能直接当文件名。
///
/// 原来所有源的状态是一整份 `source-sync-states.json`:每次扫描提交整份重新编码,
/// 启动时整份解码(服务器源 45 万首时解码瞬时多占约 800MB)。现在提交只重写变了的
/// 那个源;索引没变(同一块存储或内容相等)时只重写那个几 KB 的 JSON;启动时读
/// 二进制、校验后直接用,不经过 JSON。
///
/// 写一个源的顺序:先写新的索引文件(临时文件 → fsync → 改名),再原子替换它的
/// state.json 指过去,最后删这个源别的索引文件。任何一步中断,state.json 指着的那份
/// 索引都还在、校验也对得上;多出来的索引文件之后清掉。
public enum SourceSyncStateDirectory {
    public typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    /// state.json 的格式。不认识的版本(更新的版本写的)读的时候跳过、文件不删,
    /// 这个源当作没有已提交状态。
    public static let formatVersion = 1
    public static let directoryName = "source-sync-states"
    static let stateSuffix = ".state.json"
    static let indexSuffix = ".index"
    static let temporaryMarker = ".tmp-"
    /// 读目录时只清这么久以前的孤儿文件:同一目录下另一个还活着的写入方可能正写到一半。
    static let orphanGracePeriod: TimeInterval = 10 * 60

    public struct IndexReference: Codable, Sendable, Equatable {
        public var file: String
        public var rows: Int
        public var sha256: String

        public init(file: String, rows: Int, sha256: String) {
            self.file = file
            self.rows = rows
            self.sha256 = sha256
        }
    }

    /// 磁盘上一个源现在的样子。
    public struct Record: Sendable, Equatable {
        public var sourceID: String
        public var index: IndexReference?

        public init(sourceID: String, index: IndexReference?) {
            self.sourceID = sourceID
            self.index = index
        }
    }

    struct Envelope: Codable {
        var format: Int
        var sourceID: String
        var index: IndexReference?
        var state: SourceSyncState
    }

    public struct LoadResult: Sendable {
        public var states: [String: SourceSyncState]
        public var records: [String: Record]
        /// 非 nil 时这次启动要继续写旧的整份 JSON:迁移没能完成,旧文件仍是权威。
        /// 下次启动再迁移。
        public var legacySnapshotURL: URL?
        /// 旧文件确实读出来了(写旧格式时用:与原来 `syncStateSnapshotIsPersisted` 同义)。
        public var legacySnapshotIsPersisted: Bool
        /// 这次启动从旧文件迁过来的源个数;没有迁移为 nil。
        public var migratedSourceCount: Int?
        /// 读不了、跳过的文件与原因,给日志用。
        public var problems: [String]

        public init(
            states: [String: SourceSyncState] = [:],
            records: [String: Record] = [:],
            legacySnapshotURL: URL? = nil,
            legacySnapshotIsPersisted: Bool = false,
            migratedSourceCount: Int? = nil,
            problems: [String] = []
        ) {
            self.states = states
            self.records = records
            self.legacySnapshotURL = legacySnapshotURL
            self.legacySnapshotIsPersisted = legacySnapshotIsPersisted
            self.migratedSourceCount = migratedSourceCount
            self.problems = problems
        }
    }

    enum MigrationError: Error {
        case verificationFailed(String)
    }

    enum ReadError: Error, CustomStringConvertible {
        case unsupportedFormat(Int)
        case sourceIdentityMismatch
        case invalidIndexReference

        var description: String {
            switch self {
            case .unsupportedFormat(let format): return "unsupported format \(format)"
            case .sourceIdentityMismatch: return "source identity mismatch"
            case .invalidIndexReference: return "invalid index reference"
            }
        }
    }

    public static func directory(forLegacySnapshot legacyURL: URL) -> URL {
        legacyURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func fileStem(for sourceID: String) -> String {
        SHA256.hash(data: Data(sourceID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Launch

    /// 启动时读已提交的同步状态。
    ///
    /// 旧版本的 `source-sync-states.json` 还在,说明还没迁移、或迁移到一半被打断、或用户
    /// 降级后旧版本又写了一份:它就是最新的权威,先整份迁进新目录(写进临时目录、读回来
    /// 逐项比对、整个目录换上去),都成功了才删旧文件。迁移失败时这次启动继续写旧文件
    /// (`legacySnapshotURL`),行为与旧版本相同,下次启动再试。
    /// 旧文件解不出来(损坏)时挪到 `.corrupt` 旁边,不再每次启动重解;读不了(I/O 错误,
    /// 例如设备还没解锁)时什么都不动。
    public static func load(
        directory: URL,
        legacyURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> LoadResult {
        removeMigrationLeftovers(for: directory, fileManager: fileManager)
        var problems: [String] = []
        if fileManager.fileExists(atPath: legacyURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: legacyURL, options: .alwaysMapped)
            } catch {
                problems.append("legacy snapshot unreadable: \(error.localizedDescription)")
                var result = loadDirectory(directory, fileManager: fileManager, now: now)
                result.problems.insert(contentsOf: problems, at: 0)
                return result
            }
            let decoded: [String: SourceSyncState]
            do {
                decoded = try decodeLegacySnapshot(data)
            } catch {
                problems.append("legacy snapshot corrupt, moved aside: \(error)")
                let aside = legacyURL.appendingPathExtension("corrupt")
                try? fileManager.removeItem(at: aside)
                try? fileManager.moveItem(at: legacyURL, to: aside)
                var result = loadDirectory(directory, fileManager: fileManager, now: now)
                result.problems.insert(contentsOf: problems, at: 0)
                return result
            }
            do {
                return try migrate(decoded, into: directory, legacyURL: legacyURL, fileManager: fileManager)
            } catch {
                return LoadResult(
                    states: decoded,
                    legacySnapshotURL: legacyURL,
                    legacySnapshotIsPersisted: true,
                    problems: ["migration failed, keeping the legacy snapshot: \(error)"]
                )
            }
        }
        return loadDirectory(directory, fileManager: fileManager, now: now)
    }

    /// 旧格式:`[源 ID: SourceSyncState]` 的一整份 JSON。索引解的同时就存成紧凑形式。
    public static func decodeLegacySnapshot(_ data: Data) throws -> [String: SourceSyncState] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: SourceSyncState].self, from: data)
    }

    static func migrate(
        _ states: [String: SourceSyncState],
        into directory: URL,
        legacyURL: URL,
        fileManager: FileManager
    ) throws -> LoadResult {
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(directory.lastPathComponent + ".migrating", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // 旧版本启动时按字典键查状态,写入时用状态里的源 ID,两者一直相同;万一不同,
            // 照旧版本读的样子按字典键存。
            // 每写完一个源就从磁盘读回来逐项比对,再丢掉读回的那份:同一时刻最多多出
            // 一个源的索引,不会整份再占一遍内存。
            let decoder = makeDecoder()
            var expected: [String: SourceSyncState] = [:]
            var records: [String: Record] = [:]
            for sourceID in states.keys.sorted() {
                guard var state = states[sourceID] else { continue }
                state.sourceID = sourceID
                let record = try writeSource(
                    state, previous: nil, previousIndex: nil, in: staging, writer: nil, fileManager: fileManager
                )
                let readBack = try readSource(
                    stateFileNamed: fileStem(for: sourceID) + stateSuffix, in: staging, decoder: decoder
                )
                guard readBack.state == state, readBack.record == record else {
                    throw MigrationError.verificationFailed(sourceID)
                }
                expected[sourceID] = state
                records[sourceID] = record
            }
            let written = try fileManager.contentsOfDirectory(atPath: staging.path)
                .filter { $0.hasSuffix(stateSuffix) }
            guard Set(written) == Set(expected.keys.map { fileStem(for: $0) + stateSuffix }) else {
                throw MigrationError.verificationFailed("unexpected state files")
            }
            if fileManager.fileExists(atPath: directory.path) {
                let replaced = parent.appendingPathComponent(
                    directory.lastPathComponent + ".replaced-" + UUID().uuidString, isDirectory: true
                )
                try fileManager.moveItem(at: directory, to: replaced)
                try fileManager.moveItem(at: staging, to: directory)
                try? fileManager.removeItem(at: replaced)
            } else {
                try fileManager.moveItem(at: staging, to: directory)
            }
            do {
                try fileManager.removeItem(at: legacyURL)
            } catch {
                // 删不掉旧文件,下次启动它还会被当成权威重新迁移:这次就继续写它,
                // 免得这次启动里的提交下次被旧内容盖回去。
                return LoadResult(
                    states: expected,
                    legacySnapshotURL: legacyURL,
                    legacySnapshotIsPersisted: true,
                    problems: ["legacy snapshot could not be removed: \(error.localizedDescription)"]
                )
            }
            return LoadResult(
                states: expected,
                records: records,
                migratedSourceCount: states.count
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func removeMigrationLeftovers(for directory: URL, fileManager: FileManager) {
        let parent = directory.deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return }
        let base = directory.lastPathComponent
        for name in names where name == base + ".migrating" || name.hasPrefix(base + ".replaced-") {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: - Reading

    /// 读一个目录里所有源的状态。读不了、校验不过、格式不认识的源跳过(记进 `problems`),
    /// 它的文件留着不删,下次提交这个源时会被覆盖。`removesOrphans` 时顺带清掉
    /// 没有 state.json 引用的旧索引与临时文件(只清 `orphanGracePeriod` 之前的)。
    public static func loadDirectory(
        _ directory: URL,
        fileManager: FileManager = .default,
        removesOrphans: Bool = true,
        now: Date = Date()
    ) -> LoadResult {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return LoadResult()
        }
        let decoder = makeDecoder()
        var result = LoadResult()
        var referenced = Set<String>()
        var protectedStems = Set<String>()
        for name in names.sorted() where name.hasSuffix(stateSuffix) && !name.hasPrefix(".") {
            do {
                let source = try readSource(stateFileNamed: name, in: directory, decoder: decoder)
                if let file = source.record.index?.file { referenced.insert(file) }
                result.states[source.record.sourceID] = source.state
                result.records[source.record.sourceID] = source.record
            } catch {
                protectedStems.insert(String(name.dropLast(stateSuffix.count)))
                result.problems.append("\(name): \(error)")
            }
        }
        if removesOrphans {
            for name in names {
                let isIndex = name.hasSuffix(indexSuffix) && !name.hasPrefix(".")
                let isTemporary = name.hasPrefix(".") && name.contains(temporaryMarker)
                guard isIndex || isTemporary, !referenced.contains(name) else { continue }
                if isIndex, let stem = name.split(separator: ".").first, protectedStems.contains(String(stem)) {
                    continue
                }
                let url = directory.appendingPathComponent(name)
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                guard let modified, now.timeIntervalSince(modified) > orphanGracePeriod else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
        return result
    }

    /// Reads and verifies only one source's persisted binary index on demand.
    public static func readIndex(
        for sourceID: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> (index: SourceSyncIndex, reference: IndexReference)? {
        let stem = fileStem(for: sourceID)
        let stateURL = directory.appendingPathComponent(stem + stateSuffix)
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        let source = try readSource(
            stateFileNamed: stem + stateSuffix,
            in: directory,
            decoder: makeDecoder()
        )
        guard let reference = source.record.index else { return nil }
        return (source.state.index, reference)
    }

    /// 读一个源:state.json,再按它引用的文件名、行数、SHA-256 读回索引并校验。
    static func readSource(
        stateFileNamed name: String,
        in directory: URL,
        decoder: JSONDecoder
    ) throws -> (state: SourceSyncState, record: Record) {
        let stem = String(name.dropLast(stateSuffix.count))
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        guard envelope.format == formatVersion else { throw ReadError.unsupportedFormat(envelope.format) }
        guard fileStem(for: envelope.sourceID) == stem, envelope.state.sourceID == envelope.sourceID else {
            throw ReadError.sourceIdentityMismatch
        }
        var state = envelope.state
        state.index = SourceSyncIndex()
        if let reference = envelope.index {
            guard reference.file.hasPrefix(stem + "."), reference.file.hasSuffix(indexSuffix),
                  !reference.file.contains("/") else { throw ReadError.invalidIndexReference }
            let data = try Data(contentsOf: directory.appendingPathComponent(reference.file), options: .alwaysMapped)
            let index = try SourceSyncIndex.decodeBinary(data, expectedSHA256: reference.sha256)
            guard index.count == reference.rows else { throw SourceSyncIndexFileError.rowCountMismatch }
            state.index = index
        }
        return (state, Record(sourceID: envelope.sourceID, index: envelope.index))
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Writing

    /// 把一个源写进目录,返回写完后磁盘上的样子。`previous` / `previousIndex` 是这个源
    /// 上次写下的记录和那份索引:索引没变就沿用那个文件,只重写 state.json。
    @discardableResult
    public static func writeSource(
        _ state: SourceSyncState,
        previous: Record?,
        previousIndex: SourceSyncIndex?,
        in directory: URL,
        writer: AtomicWriter? = nil,
        fileManager: FileManager = .default
    ) throws -> Record {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = fileStem(for: state.sourceID)
        var reference: IndexReference?
        if !state.index.isEmpty {
            if let previousReference = previous?.index,
               let previousIndex,
               previousIndex.isIdentical(to: state.index) || previousIndex == state.index,
               fileManager.fileExists(atPath: directory.appendingPathComponent(previousReference.file).path) {
                reference = previousReference
            } else {
                reference = try writeIndex(state.index, stem: stem, in: directory, writer: writer, fileManager: fileManager)
            }
        }
        var metadata = state
        metadata.index = SourceSyncIndex()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(
            format: formatVersion,
            sourceID: state.sourceID,
            index: reference,
            state: metadata
        ))
        try atomicWrite(
            data,
            to: directory.appendingPathComponent(stem + stateSuffix),
            writer: writer,
            fileManager: fileManager
        )
        removeIndexFiles(stem: stem, keeping: reference?.file, in: directory, fileManager: fileManager)
        return Record(sourceID: state.sourceID, index: reference)
    }

    /// 先删 state.json(这一步之后这个源就没有已提交状态了),再删它的索引文件。
    public static func removeSource(
        _ sourceID: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let stem = fileStem(for: sourceID)
        let stateURL = directory.appendingPathComponent(stem + stateSuffix)
        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
        }
        removeIndexFiles(stem: stem, keeping: nil, in: directory, fileManager: fileManager)
    }

    private static func removeIndexFiles(
        stem: String,
        keeping kept: String?,
        in directory: URL,
        fileManager: FileManager
    ) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(stem + ".") && name.hasSuffix(indexSuffix) && name != kept {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func writeIndex(
        _ index: SourceSyncIndex,
        stem: String,
        in directory: URL,
        writer: AtomicWriter?,
        fileManager: FileManager
    ) throws -> IndexReference {
        let name = "\(stem).\(UUID().uuidString)\(indexSuffix)"
        let url = directory.appendingPathComponent(name)
        if let writer {
            let encoded = try index.binaryData()
            try writer(encoded.data, url)
            return IndexReference(file: name, rows: encoded.summary.rowCount, sha256: encoded.summary.sha256)
        }
        let summary = try writeFile(at: url, fileManager: fileManager) { handle in
            try index.writeBinary { try handle.write(contentsOf: $0) }
        }
        return IndexReference(file: name, rows: summary.rowCount, sha256: summary.sha256)
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        writer: AtomicWriter?,
        fileManager: FileManager
    ) throws {
        if let writer {
            try writer(data, url)
            return
        }
        try writeFile(at: url, fileManager: fileManager) { handle in
            try handle.write(contentsOf: data)
        }
    }

    /// 写进同目录的临时文件、fsync,再改名到目标(同名就原子替换)。
    private static func writeFile<Result>(
        at url: URL,
        fileManager: FileManager,
        _ body: (FileHandle) throws -> Result
    ) throws -> Result {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent)\(temporaryMarker)\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: temporary)
        let result: Result
        do {
            result = try body(handle)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return result
    }
}
