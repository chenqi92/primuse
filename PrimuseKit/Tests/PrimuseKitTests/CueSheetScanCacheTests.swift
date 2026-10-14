import Foundation
import Testing
@testable import PrimuseKit

@Suite("CUE scan cache")
struct CueSheetScanCacheTests {
    private static let modified = Date(timeIntervalSince1970: 1_760_000_000)

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CueSheetScanCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func version(
        size: Int64 = 12,
        modifiedDate: Date? = modified,
        revision: String? = "\"etag-1\""
    ) -> CueSheetScanCache.FileVersion? {
        CueSheetScanCache.FileVersion(size: size, modifiedDate: modifiedDate, revision: revision)
    }

    @Test("A version needs a modification time or a server revision")
    func versionNeedsChangeSignal() {
        #expect(Self.version(modifiedDate: nil, revision: nil) == nil)
        #expect(Self.version(modifiedDate: nil, revision: "  ") == nil)
        #expect(Self.version(modifiedDate: Date(timeIntervalSince1970: 0), revision: nil) == nil)
        #expect(Self.version(modifiedDate: nil, revision: "abc")?.revision == "abc")
        #expect(Self.version(revision: nil)?.modifiedMilliseconds == 1_760_000_000_000)
    }

    @Test("A sheet is reused only while path and version match")
    func sheetRoundTrip() async {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CueSheetScanCache(directory: directory)
        let data = Data("FILE \"a.wav\" WAVE".utf8)
        let version = Self.version(size: Int64(data.count))

        await cache.storeSheet(data, path: "/Album/a.cue", version: version, requestedLength: 64 * 1024)

        #expect(await cache.sheet(path: "/Album/a.cue", version: version) == data)
        #expect(await cache.sheet(path: "/Album/b.cue", version: version) == nil)
        #expect(await cache.sheet(path: "/Album/a.cue", version: Self.version(size: Int64(data.count) + 1)) == nil)
        #expect(await cache.sheet(path: "/Album/a.cue", version: Self.version(
            size: Int64(data.count),
            modifiedDate: Self.modified.addingTimeInterval(1)
        )) == nil)
        #expect(await cache.sheet(path: "/Album/a.cue", version: Self.version(
            size: Int64(data.count),
            revision: "\"etag-2\""
        )) == nil)
        #expect(await cache.sheet(path: "/Album/a.cue", version: nil) == nil)
    }

    @Test("Entries survive a new cache instance on the same directory")
    func persistsAcrossInstances() async {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 0x41, count: 300)
        let version = Self.version(size: 300)

        await CueSheetScanCache(directory: directory)
            .storeSheet(data, path: "/年轻真好/专辑.cue", version: version, requestedLength: 64 * 1024)

        #expect(await CueSheetScanCache(directory: directory)
            .sheet(path: "/年轻真好/专辑.cue", version: version) == data)
    }

    @Test("Short, unsized, unversioned and oversized reads are not stored")
    func incompleteReadsAreNotStored() async {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CueSheetScanCache(directory: directory)
        let data = Data(repeating: 0x41, count: 100)

        await cache.storeSheet(data, path: "/short.cue", version: Self.version(size: 200), requestedLength: 64 * 1024)
        await cache.storeSheet(data, path: "/unsized.cue", version: Self.version(size: -1), requestedLength: 64 * 1024)
        await cache.storeSheet(data, path: "/plain.cue", version: nil, requestedLength: 64 * 1024)
        let large = Data(repeating: 0x41, count: CueSheetScanCache.maximumSheetBytes + 1)
        await cache.storeSheet(
            large,
            path: "/large.cue",
            version: Self.version(size: Int64(large.count)),
            requestedLength: Int64(large.count)
        )

        #expect(await cache.sheet(path: "/short.cue", version: Self.version(size: 200)) == nil)
        #expect(await cache.sheet(path: "/unsized.cue", version: Self.version(size: -1)) == nil)
        #expect(await cache.sheet(path: "/large.cue", version: Self.version(size: Int64(large.count))) == nil)
    }

    @Test("A read capped by the request length still counts as complete")
    func cappedReadIsComplete() {
        #expect(CueSheetScanCache.isCompleteRead(byteCount: 256, listedSize: 10_000, requestedLength: 256))
        #expect(CueSheetScanCache.isCompleteRead(byteCount: 0, listedSize: 0, requestedLength: 64))
        #expect(!CueSheetScanCache.isCompleteRead(byteCount: 255, listedSize: 10_000, requestedLength: 256))
        #expect(!CueSheetScanCache.isCompleteRead(byteCount: 10, listedSize: -1, requestedLength: 256))
    }

    @Test("WAV DTS verdicts follow the file version and the probe revision")
    func wavVerdicts() async {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CueSheetScanCache(directory: directory)
        let version = Self.version(size: 50_000_000)

        await cache.storeWAVIsDTS(
            true, path: "/Album/a.wav", version: version,
            prefixByteCount: 256 * 1024, requestedLength: 256 * 1024
        )
        await cache.storeWAVIsDTS(
            false, path: "/Album/short.wav", version: version,
            prefixByteCount: 1024, requestedLength: 256 * 1024
        )

        #expect(await cache.wavIsDTS(path: "/Album/a.wav", version: version) == true)
        #expect(await cache.wavIsDTS(path: "/Album/a.wav", version: Self.version(size: 50_000_001)) == nil)
        #expect(await cache.wavIsDTS(path: "/Album/short.wav", version: version) == nil)
        #expect(await CueSheetScanCache(directory: directory, wavDTSProbeRevision: 2)
            .wavIsDTS(path: "/Album/a.wav", version: version) == nil)
    }

    @Test("Unreadable entries fall back to downloading")
    func corruptEntryIsIgnored() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CueSheetScanCache(directory: directory)
        let data = Data("REM".utf8)
        let version = Self.version(size: Int64(data.count))
        await cache.storeSheet(data, path: "/a.cue", version: version, requestedLength: 64 * 1024)

        let sheets = directory.appendingPathComponent("sheets", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: sheets, includingPropertiesForKeys: nil) {
            try Data("not json".utf8).write(to: file)
        }

        #expect(await cache.sheet(path: "/a.cue", version: version) == nil)
    }

    @Test("The cache lives under the source's scan directory")
    func directoryLayout() {
        let temporary = URL(fileURLWithPath: "/tmp/root", isDirectory: true)
        let directory = CueSheetScanCache.directory(sourceID: "source-1", temporaryDirectory: temporary)

        #expect(directory.lastPathComponent == "cue")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "primuse_scan_source-1")
        #expect(directory.deletingLastPathComponent().deletingLastPathComponent().path == "/tmp/root")
        // 存储管理按这个前缀统计和清除, 删源时也随之删掉。
        let root = SourceFileCacheLayout.roots.first { $0.name == "primuse_scan_" }
        #expect(root?.location == .temporary)
        #expect(root.flatMap {
            SourceFileCacheLayout.sourceID(entryName: "primuse_scan_source-1", root: $0)
        } == "source-1")
    }
}
