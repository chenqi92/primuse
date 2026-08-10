import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio duration policy")
struct AudioDurationPolicyTests {
    @Test("DTS fallback uses full-rate DTS instead of generic lossy bitrate")
    func dtsFallbackEstimate() {
        let duration = AudioDurationPolicy.fallbackEstimate(
            fileSize: 60_819_456,
            format: .dts
        )
        #expect(abs(duration - 316.768) < 0.001)
    }

    @Test("Complete-file decoder corrects an inflated scan duration")
    func completeFileDurationIsAuthoritative() {
        #expect(!AudioDurationPolicy.shouldIgnoreResolvedDuration(
            resolved: 316.813,
            stored: 2_534.144,
            fileSize: 60_819_456,
            bitRateKbps: nil,
            format: .dts,
            formatRequiresCompleteLocalFile: true
        ))
    }

    @Test("Partial range duration remains rejected for streamable files")
    func partialRangeDurationIsRejected() {
        #expect(AudioDurationPolicy.shouldIgnoreResolvedDuration(
            resolved: 30,
            stored: 300,
            fileSize: 12_000_000,
            bitRateKbps: 320,
            format: .mp3,
            formatRequiresCompleteLocalFile: false
        ))
    }

    @Test("Legacy 192 kbps DTS estimates migrate to the full-rate estimate")
    func legacyDTSEstimateIsCorrected() throws {
        let fileSize: Int64 = 43_165_697
        let legacy = Double(fileSize) * 8.0 / 192_000.0
        let corrected = try #require(AudioDurationPolicy.correctedLegacyStoredDuration(
            stored: legacy,
            fileSize: fileSize,
            format: .dts
        ))
        #expect(abs(corrected - legacy / 8.0) < 0.001)
    }

    @Test("Authoritative and non-DTS durations are not migrated")
    func validDurationsArePreserved() {
        let fileSize: Int64 = 43_165_697
        let correctedEstimate = AudioDurationPolicy.fallbackEstimate(fileSize: fileSize, format: .dts)
        #expect(AudioDurationPolicy.correctedLegacyStoredDuration(
            stored: correctedEstimate,
            fileSize: fileSize,
            format: .dts
        ) == nil)
        #expect(AudioDurationPolicy.correctedLegacyStoredDuration(
            stored: correctedEstimate * 8,
            fileSize: fileSize,
            format: .mp3
        ) == nil)
    }

    @Test("Playback handoff uses a decoder-updated library duration")
    func playbackHandoffUsesLatestDuration() {
        #expect(AudioDurationPolicy.playbackHandoffDuration(
            snapshot: 0,
            latestLibrary: 248.028979
        ) == 248.028979)

        #expect(AudioDurationPolicy.playbackHandoffDuration(
            snapshot: 300,
            latestLibrary: 248
        ) == 248)
    }

    @Test("Playback handoff preserves a valid snapshot when the library duration is unusable")
    func playbackHandoffPreservesSnapshot() {
        #expect(AudioDurationPolicy.playbackHandoffDuration(
            snapshot: 248,
            latestLibrary: nil
        ) == 248)
        #expect(AudioDurationPolicy.playbackHandoffDuration(
            snapshot: 248,
            latestLibrary: 0
        ) == 248)
        #expect(AudioDurationPolicy.playbackHandoffDuration(
            snapshot: .nan,
            latestLibrary: .infinity
        ) == 0)
    }
}

@Suite("Remote metadata memory policy")
struct RemoteMetadataReadPolicyTests {
    @Test("Large libraries start with a bounded 256 KB slice")
    func initialReadIsBounded() {
        #expect(RemoteMetadataReadPolicy.initialReadSize(fileSize: 80_000_000) == 256 * 1024)
        #expect(RemoteMetadataReadPolicy.initialReadSize(fileSize: 12_345) == 12_345)
        #expect(RemoteMetadataReadPolicy.initialReadSize(
            fileSize: 80_000_000,
            fileExtension: "MP3"
        ) == 256 * 1024)
        #expect(RemoteMetadataReadPolicy.initialReadSize(
            fileSize: 80_000_000,
            fileExtension: "flac"
        ) == 4 * 1024 * 1024)
    }

    @Test("An ID3 declaration includes MPEG probe bytes but never exceeds 4 MB")
    func id3ExpansionIsBounded() {
        #expect(RemoteMetadataReadPolicy.expandedReadSize(
            fileSize: 20_000_000,
            currentByteCount: 256 * 1024,
            declaredID3ByteCount: 700_000,
            metadataInsufficient: false
        ) == 700_000 + RemoteMetadataReadPolicy.mp3FrameProbeByteCount)
        #expect(RemoteMetadataReadPolicy.expandedReadSize(
            fileSize: 20_000_000,
            currentByteCount: 256 * 1024,
            declaredID3ByteCount: 8 * 1024 * 1024,
            metadataInsufficient: false
        ) == 4 * 1024 * 1024)
    }

    @Test("A failed first parse may retry but remains file-size bounded")
    func insufficientMetadataExpansionIsBounded() {
        #expect(RemoteMetadataReadPolicy.expandedReadSize(
            fileSize: 900_000,
            currentByteCount: 256 * 1024,
            declaredID3ByteCount: nil,
            metadataInsufficient: true
        ) == 900_000)
    }

    @Test("A truncated MP3 duration is corrected without replacing a Xing duration")
    func truncatedMP3DurationCorrection() {
        #expect(RemoteMetadataReadPolicy.correctedMP3Duration(
            parsed: 0,
            fileSize: 5_000_000,
            bitRateKbps: 192,
            providedByteCount: 256 * 1024
        ) == Double(5_000_000) / (192 * 125))

        #expect(RemoteMetadataReadPolicy.correctedMP3Duration(
            parsed: 8,
            fileSize: 5_000_000,
            bitRateKbps: 192,
            providedByteCount: 256 * 1024
        ) == Double(5_000_000) / (192 * 125))

        #expect(RemoteMetadataReadPolicy.correctedMP3Duration(
            parsed: 205,
            fileSize: 5_000_000,
            bitRateKbps: 192,
            providedByteCount: 256 * 1024
        ) == 205)

        #expect(RemoteMetadataReadPolicy.correctedMP3Duration(
            parsed: 8,
            fileSize: 300_000,
            bitRateKbps: 192,
            providedByteCount: 256 * 1024
        ) == 8)
    }

    @Test("Large ID3 artwork is excluded from the MP3 duration estimate")
    func durationExcludesLeadingID3Bytes() {
        let audioBytes: Int64 = 7_200_000
        let id3Bytes = 360_000
        #expect(RemoteMetadataReadPolicy.correctedMP3Duration(
            parsed: 8,
            fileSize: audioBytes + Int64(id3Bytes),
            bitRateKbps: 192,
            providedByteCount: 256 * 1024,
            leadingMetadataByteCount: id3Bytes
        ) == Double(audioBytes) / (192 * 125))
    }

    @Test("Container tail probes grow progressively and stay file bounded")
    func containerTailReadsAreBounded() {
        #expect(RemoteMetadataReadPolicy.containerTailReadSizes(fileSize: 8_000_000) == [
            256 * 1024,
            1024 * 1024,
            4 * 1024 * 1024,
        ])
        #expect(RemoteMetadataReadPolicy.containerTailReadSizes(fileSize: 500_000) == [
            256 * 1024,
            500_000,
        ])
    }
}

@Suite("MPEG frame header parser")
struct MPEGFrameHeaderParserTests {
    @Test("Reads MP3 bitrate and sample rate after an ID3 tag")
    func parsesConsecutiveMPEG1LayerIIIFrames() {
        var data = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0, 0, 0, 0])
        data.append(makeMP3Frame())
        data.append(makeMP3Frame())

        #expect(MPEGFrameHeaderParser.parse(data) == MPEGFrameAudioInfo(
            sampleRate: 44_100,
            bitRateKbps: 128
        ))
    }

    @Test("Rejects an isolated sync-like pattern when a following frame disagrees")
    func rejectsFalseSyncPattern() {
        var data = Data([0xFF, 0xFB, 0x90, 0x64])
        data.append(Data(repeating: 0, count: 500))
        #expect(MPEGFrameHeaderParser.parse(data) == nil)
    }

    private func makeMP3Frame() -> Data {
        // MPEG-1 Layer III, 128 kbps, 44.1 kHz, no padding => 417 bytes.
        var frame = Data([0xFF, 0xFB, 0x90, 0x64])
        frame.append(Data(repeating: 0, count: 413))
        return frame
    }
}
