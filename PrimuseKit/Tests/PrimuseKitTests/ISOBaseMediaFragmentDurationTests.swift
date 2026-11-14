import Foundation
import Testing
@testable import PrimuseKit

private let audioTimescale: UInt32 = 44_100
private let samplesPerFragment = 43
private let sampleDuration: UInt32 = 1_024
private let fragmentTicks = UInt64(samplesPerFragment) * UInt64(sampleDuration)

@Suite("Fragmented MP4 duration parsing")
struct ISOBaseMediaFragmentDurationTests {
    @Test("moov info picks the sound track, its trex default and the mehd duration")
    func movieInfo() throws {
        let moov = fragmentedMoov(mehd: 123_456, videoFirst: true)
        let info = try #require(ISOBaseMediaFragmentDuration.movieInfo(moov: moov))
        #expect(info.isFragmented)
        #expect(info.movieDuration == 0)
        #expect(info.needsFragmentDuration)
        #expect(info.movieTimescale == 1_000)
        #expect(info.trackID == 2)
        #expect(info.trackTimescale == audioTimescale)
        #expect(info.defaultSampleDurations[2] == sampleDuration)
        #expect(info.movieExtendsSeconds == 123.456)
    }

    @Test("A regular moov needs no fragment duration")
    func regularMovie() throws {
        let moov = box("moov", mvhd(timescale: 1_000, duration: 60_000) + trak(id: 1, handler: "soun"))
        let info = try #require(ISOBaseMediaFragmentDuration.movieInfo(moov: moov))
        #expect(!info.isFragmented)
        #expect(!info.needsFragmentDuration)
    }

    @Test("sidx sums subsegment durations in version 0 and version 1", arguments: [UInt8(0), UInt8(1)])
    func segmentIndex(version: UInt8) throws {
        let index = try #require(ISOBaseMediaFragmentDuration.segmentIndex(
            sidx(durations: [44_100, 88_200, 22_050], version: version)
        ))
        #expect(index.referenceID == 1)
        #expect(index.timescale == audioTimescale)
        #expect(index.totalDuration == 154_350)
        #expect(index.seconds == 3.5)
    }

    @Test("mfro gives the mfra size and tfra yields the latest entry of the requested track")
    func randomAccess() throws {
        let mfra = mfraBox(tracks: [
            (trackID: 1, entries: [(time: 9_000, moofOffset: 900)]),
            (trackID: 2, entries: [(time: 100, moofOffset: 10), (time: 5_000, moofOffset: 500), (time: 300, moofOffset: 30)]),
        ])
        #expect(ISOBaseMediaFragmentDuration.randomAccessBoxSize(mfro: Data(mfra.suffix(16))) == Int64(mfra.count))
        let entry = try #require(ISOBaseMediaFragmentDuration.lastRandomAccessEntry(mfra: mfra, trackID: 2))
        #expect(entry.trackID == 2)
        #expect(entry.time == 5_000)
        #expect(entry.moofOffset == 500)
        #expect(entry.trafNumber == 1 && entry.trunNumber == 1 && entry.sampleNumber == 1)
        let fallback = try #require(ISOBaseMediaFragmentDuration.lastRandomAccessEntry(mfra: mfra, trackID: 7))
        #expect(fallback.trackID == 1)
    }

    @Test("moof sample durations come from trun, then tfhd, then trex")
    func fragmentTiming() throws {
        let explicit = try #require(ISOBaseMediaFragmentDuration.fragmentTiming(
            moof: moofWithDurations(trackID: 2, baseTime: 4_096, durations: [1_024, 1_024, 512]),
            defaultSampleDurations: [:]
        ))
        #expect(explicit.duration(trackID: 2) == 2_560)
        #expect(explicit.fragments.first?.baseDecodeTime == 4_096)
        #expect(explicit.duration(trackID: 9) == nil)

        let tfhdDefault = try #require(ISOBaseMediaFragmentDuration.fragmentTiming(
            moof: moofWithDefault(trackID: 2, sampleCount: 10, tfhdDefault: 960),
            defaultSampleDurations: [2: 1_024]
        ))
        #expect(tfhdDefault.duration(trackID: 2) == 9_600)

        let trexDefault = try #require(ISOBaseMediaFragmentDuration.fragmentTiming(
            moof: moofWithDefault(trackID: 2, sampleCount: 10, tfhdDefault: nil),
            defaultSampleDurations: [2: 1_024]
        ))
        #expect(trexDefault.duration(trackID: 2) == 10_240)

        #expect(ISOBaseMediaFragmentDuration.fragmentTiming(
            moof: moofWithDefault(trackID: 2, sampleCount: 10, tfhdDefault: nil),
            defaultSampleDurations: [:]
        ) == nil)
    }

    @Test("End time counts from the tfra sample to the end of its traf, else tfdt plus the traf")
    func endTime() throws {
        let timing = try #require(ISOBaseMediaFragmentDuration.fragmentTiming(
            moof: moofWithDurations(trackID: 2, baseTime: 10_000, durations: [100, 200, 300, 400]),
            defaultSampleDurations: [:]
        ))
        let middle = ISOBaseMediaFragmentDuration.RandomAccessEntry(
            trackID: 2, time: 10_300, moofOffset: 0, trafNumber: 1, trunNumber: 1, sampleNumber: 3
        )
        #expect(timing.endTime(after: middle) == 11_000)
        let mismatched = ISOBaseMediaFragmentDuration.RandomAccessEntry(
            trackID: 2, time: 10_000, moofOffset: 0, trafNumber: 4, trunNumber: 1, sampleNumber: 1
        )
        #expect(timing.endTime(after: mismatched) == 11_000)
    }

    @Test("The patched moov carries the duration and is no longer fragmented")
    func patchedMovie() throws {
        let patched = try #require(ISOBaseMediaFragmentDuration.patchedMovie(
            moov: fragmentedMoov(mehd: nil),
            durationSeconds: 3_600.5
        ))
        let info = try #require(ISOBaseMediaFragmentDuration.movieInfo(moov: patched))
        #expect(!info.isFragmented)
        #expect(info.movieTimescale == 1_000)
        #expect(info.movieDuration == 3_600_500)
        #expect(patched.count == fragmentedMoov(mehd: nil).count)

        // 版本 0 的 mvhd 按 44.1 kHz 放不下 30 小时: 改成 1000。
        let overflow = try #require(ISOBaseMediaFragmentDuration.patchedMovie(
            moov: fragmentedMoov(mehd: nil, movieTimescale: audioTimescale),
            durationSeconds: 30 * 3_600
        ))
        let overflowInfo = try #require(ISOBaseMediaFragmentDuration.movieInfo(moov: overflow))
        #expect(overflowInfo.movieTimescale == 1_000)
        #expect(overflowInfo.movieDuration == 108_000_000)

        let versionOne = try #require(ISOBaseMediaFragmentDuration.patchedMovie(
            moov: fragmentedMoov(mehd: nil, mvhdVersion: 1),
            durationSeconds: 12.5
        ))
        let versionOneInfo = try #require(ISOBaseMediaFragmentDuration.movieInfo(moov: versionOne))
        #expect(versionOneInfo.movieDuration == 12_500)
        #expect(!versionOneInfo.isFragmented)
    }

    @Test("Garbage, truncated and wrong boxes parse to nothing")
    func garbage() {
        let junk = Data(repeating: 0xFF, count: 64)
        #expect(ISOBaseMediaFragmentDuration.movieInfo(moov: junk) == nil)
        #expect(ISOBaseMediaFragmentDuration.segmentIndex(junk) == nil)
        #expect(ISOBaseMediaFragmentDuration.segmentIndex(Data(sidx(durations: [1, 2], version: 0).prefix(30))) == nil)
        #expect(ISOBaseMediaFragmentDuration.randomAccessBoxSize(mfro: Data(count: 16)) == nil)
        #expect(ISOBaseMediaFragmentDuration.lastRandomAccessEntry(mfra: junk, trackID: nil) == nil)
        #expect(ISOBaseMediaFragmentDuration.fragmentTiming(moof: junk, defaultSampleDurations: [:]) == nil)
        // 截掉最后 4 字节: moof 声明的长度超出手里的字节。
        var truncated = moofWithDurations(trackID: 2, baseTime: nil, durations: [1_024])
        truncated.removeLast(4)
        #expect(ISOBaseMediaFragmentDuration.fragmentTiming(moof: truncated, defaultSampleDurations: [:]) == nil)
        // trun 声明的样本数比它自己的字节多。
        let lying = box("moof", fullBox("mfhd", be32(1)) + box(
            "traf",
            fullBox("tfhd", flags: 0x02_0000, be32(2)) + fullBox("trun", flags: 0x000100, be32(5) + be32(1_024))
        ))
        #expect(ISOBaseMediaFragmentDuration.fragmentTiming(moof: lying, defaultSampleDurations: [:]) == nil)
        #expect(ISOBaseMediaFragmentDuration.patchedMovie(moov: junk, durationSeconds: 10) == nil)
    }
}

@Suite("Fragmented MP4 duration through the range reader")
struct ISOBaseMediaFragmentRecoveryTests {
    @Test("mehd needs no request beyond the head")
    func movieExtends() async throws {
        let head = ftyp() + fragmentedMoov(mehd: 90_500)
        let file = head + fragments(count: 3)
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: head, fileSize: Int64(file.count)
        ) { _, _ in
            Issue.record("mehd is inside the head")
            return Data()
        })
        #expect(located.fragmentDuration == 90.5)
        #expect(located.fragmentDurationSource == .movieExtends)
        let info = try #require(ISOBaseMediaFragmentDuration.movieInfo(
            moov: Data(located.metadataFile.dropFirst(ftyp().count))
        ))
        #expect(!info.isFragmented)
        #expect(info.movieDuration == 90_500)
    }

    @Test("sidx right after moov, beyond the head, is one small read")
    func segmentIndexAfterMovie() async throws {
        let head = ftyp() + fragmentedMoov(mehd: nil)
        let index = sidx(durations: [UInt32](repeating: UInt32(fragmentTicks), count: 5), version: 0)
        let file = head + index + fragments(count: 5)
        let reads = ReadLog()
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: head, fileSize: Int64(file.count)
        ) { offset, count in
            reads.append(offset, count)
            return file.subdata(in: Int(offset)..<Int(offset + count))
        })
        #expect(located.fragmentDurationSource == .segmentIndex)
        #expect(located.fragmentDuration == Double(fragmentTicks * 5) / Double(audioTimescale))
        #expect(reads.count == 1)
    }

    @Test("mfra at the end gives the last random access point plus that fragment")
    func randomAccess() async throws {
        let layout = fragmentedFile(fragmentCount: 6, withRandomAccess: true)
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: layout.head, fileSize: Int64(layout.file.count)
        ) { offset, count in
            layout.file.subdata(in: Int(offset)..<Int(offset + count))
        })
        #expect(located.fragmentDurationSource == .randomAccess)
        #expect(located.fragmentDuration == Double(fragmentTicks * 6) / Double(audioTimescale))
    }

    @Test("When the last fragment cannot be read, the last random access time is a floor")
    func randomAccessFloor() async throws {
        let layout = fragmentedFile(fragmentCount: 6, withRandomAccess: true, corruptLastMoof: true)
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: layout.head, fileSize: Int64(layout.file.count)
        ) { offset, count in
            layout.file.subdata(in: Int(offset)..<Int(offset + count))
        })
        #expect(located.fragmentDurationSource == .randomAccessFloor)
        #expect(located.fragmentDuration == Double(fragmentTicks * 5) / Double(audioTimescale))
    }

    @Test("Without mehd, sidx or mfra the moof boxes are walked and summed")
    func fragmentWalk() async throws {
        let layout = fragmentedFile(fragmentCount: 4, withRandomAccess: false)
        let reads = ReadLog()
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: layout.head, fileSize: Int64(layout.file.count)
        ) { offset, count in
            reads.append(offset, count)
            return layout.file.subdata(in: Int(offset)..<Int(offset + count))
        })
        #expect(located.fragmentDurationSource == .fragmentWalk)
        #expect(located.fragmentDuration == Double(fragmentTicks * 4) / Double(audioTimescale))
        // 一个分片一个请求(moof 和后面 mdat 的头一起回来), 外加找 sidx、看 mfro 各一次。
        #expect(reads.count <= 6)
        #expect(reads.maximumCount <= 8 * 1024)
    }

    @Test("The moof walk gives up when the request budget runs out")
    func fragmentWalkBudget() async throws {
        let layout = fragmentedFile(fragmentCount: 100, withRandomAccess: false)
        let reads = ReadLog()
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: layout.head, fileSize: Int64(layout.file.count)
        ) { offset, count in
            reads.append(offset, count)
            return layout.file.subdata(in: Int(offset)..<Int(offset + count))
        })
        #expect(located.fragmentDuration == nil)
        #expect(reads.count <= ISOBaseMediaRangeReader.maximumFragmentRecoveryRequestCount)
        // moov 照样拿到, 只是没有时长。
        #expect(located.metadataFile.count > ftyp().count)
    }

    @Test("A source that ignores Range keeps the moov and just has no duration")
    func rangeIgnoringSource() async throws {
        let layout = fragmentedFile(fragmentCount: 4, withRandomAccess: true)
        let located = try #require(try await ISOBaseMediaRangeReader.readLocated(
            head: layout.head, fileSize: Int64(layout.file.count)
        ) { _, _ in
            throw MetadataRangeReadError.suffixRangeUnsupported
        })
        #expect(located.fragmentDuration == nil)
        #expect(located.fragmentDurationSource == nil)
        #expect(located.metadataFile == ftyp() + fragmentedMoov(mehd: nil))
    }

    @Test("Cancellation during recovery is not swallowed")
    func cancellation() async throws {
        let layout = fragmentedFile(fragmentCount: 4, withRandomAccess: false)
        await #expect(throws: CancellationError.self) {
            try await ISOBaseMediaRangeReader.readLocated(
                head: layout.head, fileSize: Int64(layout.file.count)
            ) { _, _ in
                throw CancellationError()
            }
        }
    }
}

// MARK: - Synthetic layouts

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [(Int64, Int64)] = []

    func append(_ offset: Int64, _ count: Int64) {
        lock.lock()
        reads.append((offset, count))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads.count
    }

    var maximumCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return reads.map(\.1).max() ?? 0
    }
}

private struct FragmentedLayout {
    let head: Data
    let file: Data
}

/// ftyp + 分片 moov(无 mehd) + N 个 moof/mdat [+ mfra]。首段只到 moov 末尾。
private func fragmentedFile(
    fragmentCount: Int,
    withRandomAccess: Bool,
    corruptLastMoof: Bool = false
) -> FragmentedLayout {
    let head = ftyp() + fragmentedMoov(mehd: nil)
    var file = head
    var entries: [(time: UInt64, moofOffset: UInt64)] = []
    for index in 0..<fragmentCount {
        let time = UInt64(index) * fragmentTicks
        entries.append((time: time, moofOffset: UInt64(file.count)))
        var fragment = moofWithDurations(
            trackID: 2,
            baseTime: time,
            durations: [UInt32](repeating: sampleDuration, count: samplesPerFragment)
        )
        if corruptLastMoof, index == fragmentCount - 1 {
            fragment.replaceSubrange(4..<8, with: Data("junk".utf8))
        }
        file += fragment + box("mdat", Data(count: 20_000))
    }
    if withRandomAccess {
        file += mfraBox(tracks: [(trackID: 2, entries: entries)])
    }
    return FragmentedLayout(head: head, file: file)
}

private func fragments(count: Int) -> Data {
    var data = Data()
    for index in 0..<count {
        data += moofWithDurations(
            trackID: 2,
            baseTime: UInt64(index) * fragmentTicks,
            durations: [UInt32](repeating: sampleDuration, count: samplesPerFragment)
        )
        data += box("mdat", Data(count: 20_000))
    }
    return data
}

private func ftyp() -> Data {
    box("ftyp", Data("iso6".utf8) + Data(count: 4) + Data("iso6dash".utf8))
}

private func fragmentedMoov(
    mehd: UInt32?,
    videoFirst: Bool = false,
    movieTimescale: UInt32 = 1_000,
    mvhdVersion: UInt8 = 0
) -> Data {
    var mvex = Data()
    if let mehd {
        mvex += fullBox("mehd", be32(mehd))
    }
    mvex += fullBox("trex", be32(2) + be32(1) + be32(sampleDuration) + be32(0) + be32(0))
    let tracks = videoFirst
        ? trak(id: 1, handler: "vide", timescale: 90_000) + trak(id: 2, handler: "soun")
        : trak(id: 2, handler: "soun")
    return box(
        "moov",
        mvhd(timescale: movieTimescale, duration: 0, version: mvhdVersion) + tracks + box("mvex", mvex)
    )
}

private func mvhd(timescale: UInt32, duration: UInt64, version: UInt8 = 0) -> Data {
    let fields = version == 1
        ? Data(count: 16) + be32(timescale) + be64(duration)
        : Data(count: 8) + be32(timescale) + be32(UInt32(duration))
    return fullBox("mvhd", version: version, fields + Data(count: 80))
}

private func trak(id: UInt32, handler: String, timescale: UInt32 = audioTimescale) -> Data {
    let tkhd = fullBox("tkhd", flags: 3, Data(count: 8) + be32(id) + Data(count: 68))
    let mdhd = fullBox("mdhd", Data(count: 8) + be32(timescale) + be32(0) + Data(count: 4))
    let hdlr = fullBox("hdlr", be32(0) + Data(handler.utf8) + Data(count: 13))
    return box("trak", tkhd + box("mdia", mdhd + hdlr))
}

private func sidx(durations: [UInt32], version: UInt8) -> Data {
    var payload = be32(1) + be32(audioTimescale)
    payload += version == 1 ? be64(0) + be64(0) : be32(0) + be32(0)
    payload += be16(0) + be16(UInt16(durations.count))
    for duration in durations {
        payload += be32(4_096) + be32(duration) + be32(0x9000_0000)
    }
    return fullBox("sidx", version: version, payload)
}

private func moofWithDurations(trackID: UInt32, baseTime: UInt64?, durations: [UInt32]) -> Data {
    var traf = fullBox("tfhd", flags: 0x02_0000, be32(trackID))
    if let baseTime {
        traf += fullBox("tfdt", version: 1, be64(baseTime))
    }
    var trun = be32(UInt32(durations.count))
    for duration in durations { trun += be32(duration) }
    traf += fullBox("trun", flags: 0x000100, trun)
    return box("moof", fullBox("mfhd", be32(1)) + box("traf", traf))
}

private func moofWithDefault(trackID: UInt32, sampleCount: UInt32, tfhdDefault: UInt32?) -> Data {
    let tfhd = tfhdDefault.map {
        fullBox("tfhd", flags: 0x02_0008, be32(trackID) + be32($0))
    } ?? fullBox("tfhd", flags: 0x02_0000, be32(trackID))
    let trun = fullBox("trun", be32(sampleCount))
    return box("moof", fullBox("mfhd", be32(1)) + box("traf", tfhd + trun))
}

/// tfra 用版本 1, traf/trun/sample 编号各 1 字节, 都是 1。
private func mfraBox(tracks: [(trackID: UInt32, entries: [(time: UInt64, moofOffset: UInt64)])]) -> Data {
    var content = Data()
    for track in tracks {
        var payload = be32(track.trackID) + be32(0) + be32(UInt32(track.entries.count))
        for entry in track.entries {
            payload += be64(entry.time) + be64(entry.moofOffset) + Data([1, 1, 1])
        }
        content += fullBox("tfra", version: 1, payload)
    }
    let size = UInt32(8 + content.count + 16)
    return box("mfra", content + fullBox("mfro", be32(size)))
}

private func box(_ type: String, _ payload: Data) -> Data {
    be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
}

private func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: Data) -> Data {
    box(type, Data([version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)]) + payload)
}

private func be16(_ value: UInt16) -> Data { bigEndianBytes(value) }
private func be32(_ value: UInt32) -> Data { bigEndianBytes(value) }
private func be64(_ value: UInt64) -> Data { bigEndianBytes(value) }

private func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
