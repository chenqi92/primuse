import Foundation
import Testing
@testable import PrimuseKit

@Suite("Codec probe over byte ranges")
struct ContainerCodecProbeTests {
    @Test("moov ahead of the audio is read in one window")
    func movieFirst() {
        let file = ftyp() + moov(tracks: [track(handler: "soun", entry: "alac")]) + mdat(200_000)
        let run = probe(file, container: .m4a)
        #expect(run.codec == .alac)
        #expect(run.reads.count == 1)
        #expect(run.reads.allSatisfy { $0.length <= ContainerCodecProbe.windowByteCount })
    }

    @Test("moov after mdat costs one more window, not the audio")
    func movieLast() {
        let file = ftyp() + mdat(3_000_000) + moov(tracks: [track(handler: "soun", entry: "mp4a")])
        let run = probe(file, container: .m4a)
        #expect(run.codec == .aac)
        #expect(run.reads.count == 2)
        #expect(run.bytesRead < 200_000)
    }

    @Test("A video track ahead of the audio is skipped, even past the first window")
    func videoTrackFirst() {
        let video = track(handler: "vide", entry: "avc1", padding: 150_000)
        let file = ftyp() + moov(tracks: [video, track(handler: "soun", entry: "alac")]) + mdat(10_000)
        let run = probe(file, container: .mp4)
        #expect(run.codec == .alac)
        #expect(run.reads.count == 2)
    }

    @Test("Unknown or missing sample entries are read-but-unknown")
    func unknown() {
        let encrypted = ftyp() + moov(tracks: [track(handler: "soun", entry: "enca")]) + mdat(1_000)
        #expect(probe(encrypted, container: .m4a).codec == nil)
        #expect(probe(encrypted, container: .m4a).finished)

        let noMovie = ftyp() + mdat(100_000)
        #expect(probe(noMovie, container: .m4a).codec == nil)
        #expect(probe(noMovie, container: .m4a).finished)

        let garbage = [UInt8](repeating: 0xFF, count: 4_096)
        #expect(probe(garbage, container: .m4a).codec == nil)
        #expect(probe(garbage, container: .m4a).reads.count == 1)
    }

    @Test("Formats outside the multi-codec containers are never read")
    func otherFormats() {
        let probe = ContainerCodecProbe(container: .flac, fileSize: 1_000)
        #expect(probe.step == .finished(nil))
    }

    @Test("CAF goes through the header parser")
    func caf() {
        var file = Array("caff".utf8) + [0, 1, 0, 0] + Array("desc".utf8) + be64(32)
        file += be64(Double(44_100).bitPattern) + Array("alac".utf8) + be32(1)
        file += be32(4_096) + be32(4_096) + be32(2) + be32(0)
        file += [UInt8](repeating: 0, count: 600_000)
        #expect(probe(file, container: .caf).codec == .alac)
    }

    // MARK: - Driver

    private struct Run {
        var codec: AudioFormat?
        var finished = false
        var reads: [(offset: Int64, length: Int64)] = []
        var bytesRead: Int64 { reads.reduce(0) { $0 + $1.length } }
    }

    private func probe(_ file: [UInt8], container: AudioFormat) -> Run {
        var probe = ContainerCodecProbe(container: container, fileSize: Int64(file.count))
        var run = Run()
        while case .read(let offset, let length) = probe.step, run.reads.count < 20 {
            run.reads.append((offset, length))
            let start = Int(offset)
            let end = min(file.count, start + Int(length))
            probe.consume(start < end ? Data(file[start..<end]) : Data())
        }
        if case .finished(let codec) = probe.step {
            run.codec = codec
            run.finished = true
        }
        return run
    }

    // MARK: - Fixtures

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { (0..<4).reversed().map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(8 + payload.count) + Array(type.utf8) + payload
    }

    private func ftyp() -> [UInt8] {
        box("ftyp", Array("M4A ".utf8) + be32(0) + Array("M4A mp42isom".utf8))
    }

    private func mdat(_ count: Int) -> [UInt8] {
        box("mdat", [UInt8](repeating: 0x5A, count: count))
    }

    private func moov(tracks: [[UInt8]]) -> [UInt8] {
        box("moov", box("mvhd", [UInt8](repeating: 0, count: 100)) + tracks.flatMap { $0 }
            + box("udta", box("meta", [UInt8](repeating: 0, count: 64))))
    }

    /// `padding` 撑大 stsd 前面的盒子,模拟视频轨很长的采样表。
    private func track(handler: String, entry: String, padding: Int = 0) -> [UInt8] {
        let hdlr = box("hdlr", [0, 0, 0, 0] + be32(0) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
        let sampleEntry = box(entry, [UInt8](repeating: 0, count: 6) + be16(1) + [UInt8](repeating: 0, count: 8)
            + be16(2) + be16(16) + [0, 0, 0, 0] + be32(44_100 << 16))
        let stsd = box("stsd", [0, 0, 0, 0] + be32(1) + sampleEntry)
        let stbl = box("stbl", stsd + box("stts", be32(0) + be32(0)))
        let filler = padding > 0 ? box("free", [UInt8](repeating: 0, count: padding)) : []
        let minf = box("minf", box("smhd", [UInt8](repeating: 0, count: 8)) + filler + stbl)
        let mdia = box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24)) + hdlr + minf)
        return box("trak", box("tkhd", [UInt8](repeating: 0, count: 84)) + mdia)
    }
}
