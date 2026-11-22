import CryptoKit
import Foundation

/// 各个源的已提交同步状态,每个源各存各的文件,放在 `source-sync-states/` 目录里:
/// - `<stem>.state.json`:除索引以外的全部字段(仍由 `SourceSyncState` 的 Codable 决定,
///   以后加的字段照常进去),外加它引用的索引文件名、行数与 SHA-256;
/// - `<stem>.<UUID>.index`:紧凑索引能直接映射的二进制(`SourceSyncIndex.writeBinary(mappable:)`,
///   第 2 版),索引为空时没有这个文件。读的时候映射进来(`SourceSyncIndex.mapFile`),
///   常驻的已提交索引不占堆;旧版本写的第 1 版文件读进堆里,之后在后台改写成第 2 版
///   (`SourceSyncStateFileStore.upgradeIndexFormats`,失败了按 `FormatUpgradeBackoff` 退避)。
/// 索引文件读不回来时这个源的其余字段照旧读出来,索引为空、`indexBaselineLost` 为真。
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
        /// 索引是旧格式(或哈希表要重算)、这次读进了堆里的源:之后在后台改写成能映射的格式。
        public var pendingFormatUpgrades: Set<String>

        public init(
            states: [String: SourceSyncState] = [:],
            records: [String: Record] = [:],
            legacySnapshotURL: URL? = nil,
            legacySnapshotIsPersisted: Bool = false,
            migratedSourceCount: Int? = nil,
            problems: [String] = [],
            pendingFormatUpgrades: Set<String> = []
        ) {
            self.states = states
            self.records = records
            self.legacySnapshotURL = legacySnapshotURL
            self.legacySnapshotIsPersisted = legacySnapshotIsPersisted
            self.migratedSourceCount = migratedSourceCount
            self.problems = problems
            self.pendingFormatUpgrades = pendingFormatUpgrades
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
                // 留读回来的那份:它的索引映射着刚写的文件,不占堆;解码出来的那份随即放掉。
                // 临时目录整个改名换上去不影响已经映射的文件。
                expected[sourceID] = readBack.state
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
                switch source.outcome {
                case .mapped, .heap:
                    break
                case .heapNeedsFormatUpgrade:
                    result.pendingFormatUpgrades.insert(source.record.sourceID)
                case .baselineLost(let reason):
                    result.problems.append("\(name): index unreadable, kept the rest for a full rescan: \(reason)")
                }
                // 读不回来的索引文件也留到下次提交这个源时再换掉。
                if let file = source.referencedIndexFile { referenced.insert(file) }
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

    /// 一个源的索引读成了什么样。
    enum IndexLoadOutcome: Equatable {
        /// 映射的(或者本来就没有索引)。
        case mapped
        /// 旧格式或哈希表要重算:读进了堆里,之后在后台改写成能映射的格式。
        case heapNeedsFormatUpgrade
        /// 映射不了、或开放寻址表探测太长:读进了堆里,文件本身没问题,不改写。
        case heap
        /// 读不回来:索引为空,其余字段照旧,`indexBaselineLost` 为真。
        case baselineLost(String)
    }

    /// 读一个源:state.json,再按它引用的文件名、行数、SHA-256 读回索引并校验。
    /// state.json 本身读不了(格式、身份不对)时报错,这个源跳过;只是索引读不回来时
    /// 其余字段照旧返回,索引为空并记下 `indexBaselineLost`:删歌证词、确认中的大批消失
    /// 都还在,下一次完整走查照常走删除确认,不会因为没有上一份状态就一次删掉。
    static func readSource(
        stateFileNamed name: String,
        in directory: URL,
        decoder: JSONDecoder
    ) throws -> (state: SourceSyncState, record: Record, outcome: IndexLoadOutcome, referencedIndexFile: String?) {
        let stem = String(name.dropLast(stateSuffix.count))
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        guard envelope.format == formatVersion else { throw ReadError.unsupportedFormat(envelope.format) }
        guard fileStem(for: envelope.sourceID) == stem, envelope.state.sourceID == envelope.sourceID else {
            throw ReadError.sourceIdentityMismatch
        }
        var state = envelope.state
        state.index = SourceSyncIndex()
        guard let reference = envelope.index else {
            return (state, Record(sourceID: envelope.sourceID, index: nil), .mapped, nil)
        }
        guard reference.file.hasPrefix(stem + "."), reference.file.hasSuffix(indexSuffix),
              !reference.file.contains("/") else {
            state.indexBaselineLost = true
            return (state, Record(sourceID: envelope.sourceID, index: nil),
                    .baselineLost("\(ReadError.invalidIndexReference)"), nil)
        }
        do {
            let read = try readIndex(reference, in: directory)
            state.index = read.index
            return (state, Record(sourceID: envelope.sourceID, index: reference), read.outcome, reference.file)
        } catch {
            // 磁盘上没有可用的索引:记录里也不带它,下次提交这个源时写新的、换掉这个文件。
            state.indexBaselineLost = true
            return (state, Record(sourceID: envelope.sourceID, index: nil), .baselineLost("\(error)"), reference.file)
        }
    }

    private static func readIndex(
        _ reference: IndexReference,
        in directory: URL
    ) throws -> (index: SourceSyncIndex, outcome: IndexLoadOutcome) {
        let url = directory.appendingPathComponent(reference.file)
        func decodeIntoHeap() throws -> SourceSyncIndex {
            try SourceSyncIndex.decodeBinary(Data(contentsOf: url, options: .alwaysMapped), expectedSHA256: reference.sha256)
        }
        let index: SourceSyncIndex
        let outcome: IndexLoadOutcome
        do {
            index = try SourceSyncIndex.mapFile(at: url, expectedSHA256: reference.sha256)
            outcome = .mapped
        } catch SourceSyncIndexFileError.unsupportedVersion(let version)
                    where version < SourceSyncIndex.mappableFormatVersion {
            index = try decodeIntoHeap()
            outcome = .heapNeedsFormatUpgrade
        } catch SourceSyncIndexFileError.hashTableMismatch {
            // 哈希算法改过(或系统的 NFC 规则变了):内容仍然可信,读进堆里重算,之后再写一份。
            index = try decodeIntoHeap()
            outcome = .heapNeedsFormatUpgrade
        } catch SourceSyncIndexFileError.excessiveProbing {
            // 开放寻址表里有过长的探测链(大量键的哈希挤在一起):映射着查会很慢,读进堆里用。
            // 重写也还是同样的键,不改写。
            index = try decodeIntoHeap()
            outcome = .heap
        } catch SourceSyncIndexFileError.mappingFailed {
            // 映射不了(例如地址空间不够):照旧整份读进堆里,文件本身没问题,不改写。
            index = try decodeIntoHeap()
            outcome = .heap
        }
        guard index.count == reference.rows else { throw SourceSyncIndexFileError.rowCountMismatch }
        return (index, outcome)
    }

    /// 映射一个源刚写下(或沿用)的索引文件。提交之后用它换掉堆上那份:常驻的已提交索引
    /// 从此不占堆。没有索引文件(空索引)时返回 nil。
    public static func mapIndex(for record: Record, in directory: URL) throws -> SourceSyncIndex? {
        guard let reference = record.index else { return nil }
        let index = try SourceSyncIndex.mapFile(
            at: directory.appendingPathComponent(reference.file), expectedSHA256: reference.sha256
        )
        guard index.count == reference.rows else { throw SourceSyncIndexFileError.rowCountMismatch }
        return index
    }

    /// 旧格式索引改写失败后的退避记录(按文件名前缀记),存在目录里的 `format-upgrade-backoff.json`。
    /// 失败一次等一天再试,之后每次翻倍,最多等 30 天:不在每次启动都整份重写几百 MB。
    public struct FormatUpgradeBackoff: Codable, Sendable, Equatable {
        public struct Attempt: Codable, Sendable, Equatable {
            public var failures: Int
            public var lastFailureAt: Date
        }

        public static let fileName = "format-upgrade-backoff.json"
        public static let initialDelay: TimeInterval = 24 * 60 * 60
        public static let maximumDelay: TimeInterval = 30 * 24 * 60 * 60

        public var attempts: [String: Attempt] = [:]

        public init() {}

        public func allowsAttempt(stem: String, now: Date) -> Bool {
            guard let attempt = attempts[stem] else { return true }
            let exponent = Double(Swift.min(Swift.max(attempt.failures - 1, 0), 16))
            let delay = Swift.min(Self.maximumDelay, Self.initialDelay * pow(2, exponent))
            return now.timeIntervalSince(attempt.lastFailureAt) >= delay
        }

        public mutating func recordFailure(stem: String, at date: Date) {
            let failures = (attempts[stem]?.failures ?? 0) + 1
            attempts[stem] = Attempt(failures: failures, lastFailureAt: date)
        }

        public mutating func recordSuccess(stem: String) {
            attempts[stem] = nil
        }

        public static func load(from directory: URL) -> FormatUpgradeBackoff {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
                  let decoded = try? makeDecoder().decode(FormatUpgradeBackoff.self, from: data) else {
                return FormatUpgradeBackoff()
            }
            return decoded
        }

        public func save(to directory: URL) throws {
            let url = directory.appendingPathComponent(Self.fileName)
            guard !attempts.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
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
            let encoded = try index.binaryData(mappable: true)
            try writer(encoded.data, url)
            return IndexReference(file: name, rows: encoded.summary.rowCount, sha256: encoded.summary.sha256)
        }
        let summary = try writeFile(at: url, fileManager: fileManager) { handle in
            try index.writeBinary(mappable: true) { try handle.write(contentsOf: $0) }
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
