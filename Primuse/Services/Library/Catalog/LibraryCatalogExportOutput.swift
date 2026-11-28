import Foundation

/// 整库快照(带歌)编出来之后放在哪(DL3)。以前攒在一份内存里的 `Data`:5.5 万首约 49 MB,iCloud 上传整理、压缩、
/// 网络往返的整段时间里都握着,App 在这期间被挂起就带着它挂起(真机第 5 轮:放掉模型之后的后台上传,malloc 在用的
/// 从 90 涨到 142 MiB,挂起时停在 260 MiB)。现在一页一页写进临时文件,编完把文件映射回来交出去,映射之后文件名
/// 立刻删掉(映射一直有效到这份 `Data` 放掉)。映射的页是文件背着的干净页:不算 malloc、不算脏内存,系统缺内存时
/// 直接收回,要读时再从文件读。拿到的照旧是 `Data`,字节与攒在内存里时逐字节相同。
/// 临时文件建不了时退回内存(与以前相同);写到一半写不下去(磁盘满)时把写过的读回内存接着编,不让导出失败。
/// 写过的也读不回来时 `finish()` 报错(DL4):宁可这一次不传,也不交出缺了开头的快照。
/// iCloud 上传前的整理(DL4)也用它:整理好的歌先写进一份,再与小状态拼成交出去的那一份。
final class LibraryCatalogExportOutput {
    /// 攒满这么多再写一次文件(一页 1000 首约 1 MB,差不多一页一写)。
    static let bufferLimit = 1 << 20

    #if DEBUG
    /// 测试与规模夹具:true 时照以前那样只攒在内存里,好与写文件的那一份比字节、比内存。
    nonisolated(unsafe) static var keepsInMemoryForTesting = false
    /// 测试:写进文件的字节超过这么多时让写入失败(像磁盘满了);`failsReadBackForTesting` 再让读回也失败。
    nonisolated(unsafe) static var failsWritesBeyondBytesForTesting: Int?
    nonisolated(unsafe) static var failsReadBackForTesting = false
    #endif

    /// 文件写不下去、写过的又读不回来:这一份已经缺了开头,`finish()` 报错,不交出残缺的快照。
    private var lostWrittenBytes = false

    private var handle: FileHandle?
    private var url: URL?
    private var memory = Data()
    private var buffer = Data()
    /// 已经完整写进文件的字节数(写到一半出错时文件尾可能多出半块,读回时只取这么多)。
    private var written = 0
    /// 已经交进来的字节数(写进文件的加上还在缓冲里的),判「超过上限」用。
    private(set) var count = 0

    init(head: Data) {
        if Self.startsWithAFile, let file = Self.makeFile() {
            handle = file.handle
            url = file.url
            buffer.reserveCapacity(Self.bufferLimit + Self.bufferLimit / 4)
        }
        append(head)
    }

    deinit {
        try? handle?.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func append(_ byte: UInt8) {
        append(Data([byte]))
    }

    func append(contentsOf bytes: [UInt8]) {
        append(Data(bytes))
    }

    func append(_ bytes: Data) {
        count += bytes.count
        guard !lostWrittenBytes else { return }
        guard handle != nil else {
            memory.append(bytes)
            return
        }
        // 大块(整理之后的整份)直接写,不先抄进缓冲。
        if bytes.count >= Self.bufferLimit {
            flush()
            write(bytes)
        } else {
            buffer.append(bytes)
            if buffer.count >= Self.bufferLimit { flush() }
        }
    }

    /// 编完:文件映射回来(删掉文件名)交出去;退回内存的交内存里的那一份。之后不要再追加。
    func finish() throws -> Data {
        guard !lostWrittenBytes else { throw CocoaError(.fileReadUnknown) }
        guard let handle, let url else { return memory }
        flush()
        // flush 写失败时已经退回了内存(读不回来时报错)。
        guard !lostWrittenBytes else { throw CocoaError(.fileReadUnknown) }
        guard self.handle != nil else { return memory }
        try handle.close()
        self.handle = nil
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try? FileManager.default.removeItem(at: url)
        self.url = nil
        return data
    }

    /// 一份已经在内存里的整库快照(iCloud 上传整理之后编出的那一份)换成文件背着的同样字节,原来那份随调用方放掉。
    /// 写不了时原样交回。
    static func fileBacked(_ data: Data) -> Data {
        guard startsWithAFile, data.count >= bufferLimit else { return data }
        let output = LibraryCatalogExportOutput(head: data)
        return (try? output.finish()) ?? data
    }

    private static var startsWithAFile: Bool {
        #if DEBUG
        if keepsInMemoryForTesting { return false }
        #endif
        return true
    }

    private func flush() {
        guard handle != nil, !buffer.isEmpty else { return }
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        write(pending)
    }

    private func write(_ bytes: Data) {
        guard let handle else {
            memory.append(bytes)
            return
        }
        do {
            #if DEBUG
            if let limit = Self.failsWritesBeyondBytesForTesting, written + bytes.count > limit {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            #endif
            try handle.write(contentsOf: bytes)
            written += bytes.count
        } catch {
            // 写不下去:写过的读回内存,这一块接上,后面照内存那样接着编。
            plog("☁️ whole-library export: the temporary file stopped accepting writes (\(error)); continuing in memory")
            try? handle.close()
            self.handle = nil
            #if DEBUG
            let readBack = Self.failsReadBackForTesting ? nil : url.flatMap { try? Data(contentsOf: $0) }
            #else
            let readBack = url.flatMap { try? Data(contentsOf: $0) }
            #endif
            if let readBack, readBack.count >= written {
                var recovered = Data(readBack.prefix(written))
                recovered.append(buffer)
                recovered.append(bytes)
                memory = recovered
            } else {
                // 以前读不回来时当作空的接着编,交出去的是缺了开头的快照。
                plog("☁️ whole-library export: the bytes already written cannot be read back; the export fails")
                lostWrittenBytes = true
                memory = Data()
            }
            buffer = Data()
            if let url { try? FileManager.default.removeItem(at: url) }
            url = nil
        }
    }

    private static let filePrefix = "primuse-library-export-"

    /// 上一次进程在写到一半时退出留下的临时文件,这一轮进程第一次导出时清掉。
    private static let staleFilesRemoved: Void = {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }()

    private static func makeFile() -> (handle: FileHandle, url: URL)? {
        _ = staleFilesRemoved
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filePrefix + UUID().uuidString + ".json")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        return (handle, url)
    }
}
