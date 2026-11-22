import AVFoundation
import AudioToolbox
import XCTest
@testable import Primuse

@MainActor
final class EmbeddedKaraokeAudioTests: XCTestCase {
    func testSelectsOnlyRequestedAudioOrdinalsAndKeepsContainerTimeline() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, fixture) in [("song.mka", Self.matroska), ("song.stem.mp4", Self.mp4)] {
            let input = directory.appendingPathComponent(name)
            let data = try XCTUnwrap(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
            try (data as NSData).decompressed(using: .zlib).write(to: input)
            let output = directory.appendingPathComponent("selected.caf")

            func channels(_ selection: [Int]) async throws -> [[Float]] {
                try await EmbeddedKaraokeAudio.render(from: input, audioOrdinals: selection, to: output)
                let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
                XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
                XCTAssertEqual(file.fileFormat.channelCount, 2)
                XCTAssertEqual(file.length, 5_280, name)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5_280))
                try file.read(into: buffer)
                let samples = try XCTUnwrap(buffer.floatChannelData)
                let frames = Int(buffer.frameLength)
                return (0..<2).map { Array(UnsafeBufferPointer(start: samples[$0], count: frames)) }
            }

            let master = try await channels([0])
            let drums = try await channels([1])
            let bass = try await channels([2])
            let mix = try await channels([2, 1, 2])
            let last = try await channels([3, 4])
            let silent = try await channels([])
            let lead = Array<Float>(repeating: 0, count: 480)
            XCTAssertEqual(master[0], lead + Array(repeating: 0.25, count: 4_800), name)
            XCTAssertEqual(drums[0], lead + Array(repeating: 0.125, count: 2_160) + Array(repeating: 0, count: 2_640), name)
            XCTAssertEqual(bass[1], Array(repeating: 0, count: 1_440) + Array(repeating: 0.125, count: 2_160)
                           + Array(repeating: 0, count: 1_680), name)
            for i in 0..<2 {
                XCTAssertEqual(mix[i], zip(drums[i], bass[i]).map(+), name)
                XCTAssertTrue(silent[i].allSatisfy { $0 == 0 }, name)
            }
            XCTAssertEqual(last[0], lead + Array(repeating: -0.03125, count: 4_800), name)
            XCTAssertEqual(last[1], lead + Array(repeating: 0.0625, count: 4_800), name)
        }
    }

    func testCancelledMissingAndInvalidTracksPreserveExistingOutput() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("song.mka")
        let output = directory.appendingPathComponent("selected.caf")
        let subtitle = directory.appendingPathComponent("caption.srt")
        let prior = Data("existing output".utf8)
        try prior.write(to: output)
        try Data("1\n00:00:00,000 --> 00:00:00,100\n海潮托起纸帆\n".utf8).write(to: subtitle)
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.matroska, options: .ignoreUnknownCharacters))
        try (bytes as NSData).decompressed(using: .zlib).write(to: input)

        for (url, selection) in [(input, [0, 9]), (input, [-1]), (subtitle, [])] {
            do {
                try await EmbeddedKaraokeAudio.render(from: url, audioOrdinals: selection, to: output)
                XCTFail("Unavailable audio selection succeeded")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: output), prior)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await EmbeddedKaraokeAudio.render(from: input, audioOrdinals: [1], to: output)
        }
        do {
            try await cancelled.value
            XCTFail("Cancelled render replaced the output")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: output), prior)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), Set([input.lastPathComponent, output.lastPathComponent, subtitle.lastPathComponent]))
    }

    func testNewSelectionSupersedesAnInFlightWriteToTheSameDestination() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let longFile = directory.appendingPathComponent("long.caf")
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var handle: AudioFileID?
        XCTAssertEqual(AudioFileCreateWithURL(longFile as CFURL, kAudioFileCAFType, &format, [], &handle), noErr)
        let file = try XCTUnwrap(handle)
        var zero: UInt64 = 0
        var size: UInt32 = 8
        // A sparse source keeps this test deterministic without storing ten minutes of PCM.
        XCTAssertEqual(AudioFileWriteBytes(file, false, 600 * 48_000 * 8 - 8, &size, &zero), noErr)
        XCTAssertEqual(AudioFileClose(file), noErr)
        let shortFile = directory.appendingPathComponent("short.mka")
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.matroska, options: .ignoreUnknownCharacters))
        try (bytes as NSData).decompressed(using: .zlib).write(to: shortFile)
        let output = directory.appendingPathComponent("selected.caf")
        let first = Task { try await EmbeddedKaraokeAudio.render(from: longFile, audioOrdinals: [0], to: output) }
        defer { first.cancel() }
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(5)
        while try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".") }) {
            guard clock.now < limit else {
                first.cancel()
                _ = try? await first.value
                return XCTFail("First render never started its output")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await EmbeddedKaraokeAudio.render(from: shortFile, audioOrdinals: [], to: output)
        do {
            try await first.value
            XCTFail("Superseded render published its audio")
        } catch is CancellationError {}
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 5_280)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       [longFile.lastPathComponent, output.lastPathComponent, shortFile.lastPathComponent].sorted())
    }

    private func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    // Lossless PCM/ALAC containers with a subtitle and five distinct audio tracks. Music starts at
    // 10 ms. Bass starts at 30 ms, bass and drums last 45 ms, and the whole movie ends at 110 ms.
    private static let matroska = """
        7d1PaJNnHMDxJ2/fFPWyVjYZIlplCHqw6cG/lyVpMqjt29YmdQMP5TXWOGu19G29eMmTvE2yZRVFGGJFLcHBsBRscS2GkYkVethg
        twgeRMF2hyG6IVHYhu/7pi710INVyKHffPuhfdK+P540OeTQvu/64MNs1p+ULn/R8pdU/X/LVf54ulcf6D9l9Oj+lHXXkFQ+DcWi
        LmHdXNv+q9VGBu7kzQf344qWy4RumJ80/Xg0NCZHS6t14fEea/WrlvvOWq0N342GxuLKlJYbtpYbQjnrmwnXtkt/OuOE6BAf/Gbv
        54e8OT0pzmwv3Ex85PdqMbNFP330S5/zKfBN2nso5vyovVnfk7w5o62dHF/YUX1Buox76YVhrstSbLl1OTF48khaimQm1BUOfhWu
        7wx/sSchazufSvHmuP0FqZSPU6zjQieTmm4MdPcvDEgO+7raG7X6ptZwfUtTOCGVR+evSuVW2jvf5xx0+IisWTyypSCryiOrnJFD
        gf7BXmPRlt51aHNBquWhqjPU9OvG+8y0Nuouz3SXNto2cOz/h76coVpBVpeHVpd+oQdPRfQTy9mq/Ur0vcibr2pqDxjGb5FfMpHy
        kxydvRjMpoKtjW2BYEcglbFeJpE6Y/Bw/9d90dnRYDYd6OzwhZvaWgOpCx7PPudjh2evp3QThvH7W/OU6OzI4nlnnXl9kd4uo2HX
        ie6lRzY0LDWyarkjPTt3LjFSXfbI3UuNdH/4B179/iM3Nf40uPmzR3nzylj38Xm55trI6PfSGj1/e/rJdHLu7LU/8qm5i9fnfh4f
        ke3ZOq8aFyIm6oiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIio0mX1mYR9GoAa8RIAAAAAAAAAAAAAAACVY1/OYcj+Ow4h
        VgEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgMqyzwOQtM8D8I+1AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFZXVZ0zxcUy8FDUAAAAA
        AAAAAAAAAAConGyzGhedMVFHRERERLRyst4GD9lvg7nAGwAAAFbSxX2b1aT9Npj/bwQAAMAKsiGU63mYN4ufP57I3ZuUa6aGi9L1
        PK5OPJOrJ2T71LdFqZSWW6cyRVnlfB337rAX7tJCf2EvqkuL0X9z5yblRvsetXTPY/dr
        """

    private static let mp4 = """
        7VZPSBRRGH9vxs3F1hxEqMMSG1hKKJh/MILQJCio8FAWiWCzO7N/cGZ3m3kr1kUlaQ9RSBB09FDQqWNIEYl06tStDh4UavVSePAo
        vd6bfTv7Zlxnd100hAbefO+9+d73vvf7/eabAQAEo+hBOmGmdAAEQC1p3Xq69xwAwB81VBUA8Z2uyIiMm9ffL/5cfJx7trDxKZt7
        +Tr38W2ITIPGAIz9icI+3AtiOOcYrWPLY48XxE0v8HwNAQDOftkMAQkAaZXlGYc9XJ6F0TqW9pCdvxE/wksVuk8v+xYtMJr8kE05
        gcNZjJcr3n1gbWulBPp2cIhFPFMWnW8Da3i7MoDqy4azw84dnf5cPVfTy+KUlYpvpkwqtWlKGKlRU7NnN+08XWTaGePZ8WrIXL2+
        ssvRqyN0tn9g9c427QYW9FRqknQ0fTKuON3EDXJLAhIYOqBxQ+UcDnrvXU8qSAAZ8gTpj6EJa0+xRLRRPpE97NuqKsgkNqhqJuJW
        jBbXwjldScikE9IV19mbhgYBHJ8fyeuzK65oRuGRGUYa73ozE0YJpKlX5aSiqdQNduiJZJSCm9TtuK1Kfi6oGGqUyyeQMbQQ62+Z
        KExjKyYyFc7nFprqifGnhpiy6EJDwuSi9TeK5DAZQ98lIyHTeC1hZDAM/CP5BtpNZOFTwJfEbZMsC8/PcOgSPzPC+gKbd1vaQsTv
        oYsz+ryF2RMmiqS4OB3E5Tvpih5aEJhN8ueE1Wuhi2mhndMCjd1gIZZfq3DopnbVBfhAsGleYrpoc+gileHzBDdkE+XlEGJykEzd
        Ea4SSfxgktBckhiTNTmy4/ACkApJ0vhFH1q52xuOWYAO1oHj6YJXURpwi9xiS3kqbWkwiiW2j0CfBzlJQFcLumRA178i7U0JCQwR
        85ws++2SgLDj1Qeg/wAk0MlJYNRbAv40k8AZLwlcNjI63RQGalDA14NVwL1snilbAYxZf7oM8y0c80+KczbjdJwj5pcH23XMXtsn
        tk/uwvbdCtk+7cX2kGz+J7voL9AvveBBtu8fVfdkhdXd89UeRvFDV9y7F/ahuA/TX6CdxR3eJ7X7QonvO6+AI4f5+347FZE185BJ
        oHM/JHCFVWy3BEgs8SnpX8woiMLdp6uWpdcpHlpChyGn047fan+CQPIX
        """
}
