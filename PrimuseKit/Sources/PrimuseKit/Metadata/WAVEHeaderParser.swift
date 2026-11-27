import Foundation

/// Reads the fixed-size RIFF/WAVE headers that are available in a remote
/// file's initial byte range. The `data` chunk advertises its complete byte
/// count even when the provided `Data` contains only a small prefix, so this
/// avoids treating a 256 KB metadata Range response as the whole song.
public enum WAVEHeaderParser {
    public struct AudioInfo: Equatable, Sendable {
        public let duration: TimeInterval
        public let sampleRate: Int
        public let bitRateKbps: Int
        public let bitDepth: Int
        public let channelCount: Int

        public init(
            duration: TimeInterval,
            sampleRate: Int,
            bitRateKbps: Int,
            bitDepth: Int,
            channelCount: Int
        ) {
            self.duration = duration
            self.sampleRate = sampleRate
            self.bitRateKbps = bitRateKbps
            self.bitDepth = bitDepth
            self.channelCount = channelCount
        }
    }

    public static func parse(_ data: Data) -> AudioInfo? {
        guard data.count >= 12,
              ascii(data, at: 0) == "RIFF",
              ascii(data, at: 8) == "WAVE" else {
            return nil
        }

        var cursor = 12
        var sampleRate: UInt32?
        var byteRate: UInt32?
        var bitDepth: UInt16?
        var channelCount: UInt16?
        var audioByteCount: UInt32?

        while cursor <= data.count - 8 {
            guard let chunkSize = littleEndianUInt32(data, at: cursor + 4) else { break }
            let chunkID = ascii(data, at: cursor)
            let payloadStart = cursor + 8

            if chunkID == "fmt ", chunkSize >= 16, payloadStart <= data.count - 16 {
                channelCount = littleEndianUInt16(data, at: payloadStart + 2)
                sampleRate = littleEndianUInt32(data, at: payloadStart + 4)
                byteRate = littleEndianUInt32(data, at: payloadStart + 8)
                bitDepth = littleEndianUInt16(data, at: payloadStart + 14)
            } else if chunkID == "data" {
                audioByteCount = chunkSize
                break
            }

            let paddedSize = UInt64(chunkSize) + UInt64(chunkSize & 1)
            let next = UInt64(payloadStart) + paddedSize
            guard next <= UInt64(data.count), next <= UInt64(Int.max) else { break }
            cursor = Int(next)
        }

        guard let sampleRate, sampleRate > 0,
              let byteRate, byteRate > 0,
              let bitDepth, bitDepth > 0,
              let channelCount, channelCount > 0,
              let audioByteCount, audioByteCount > 0 else {
            return nil
        }

        let duration = Double(audioByteCount) / Double(byteRate)
        guard duration.isFinite, duration > 0 else { return nil }

        return AudioInfo(
            duration: duration,
            sampleRate: Int(sampleRate),
            bitRateKbps: (Double(byteRate) * 8.0 / 1000.0).rounded().finiteInt(),
            bitDepth: Int(bitDepth),
            channelCount: Int(channelCount)
        )
    }

    private static func ascii(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii)
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
