import Foundation
import ImageIO

/// Detects a JPEG sampling layout that some FFmpeg encoders emit and Apple
/// ImageIO cannot decode reliably (`decodeImageImp failed - NULL _blockArray`).
/// The check parses only JPEG marker headers, so callers can reject or replace
/// the data without first triggering ImageIO's decoder.
public enum ArtworkImageCompatibility {
    /// ImageIO can render a partial JPEG/PNG and report a valid first frame
    /// even when the transfer ended early. Such a bitmap typically contains a
    /// black lower half or repeated scan blocks and must never enter the cover
    /// cache. Require both the container and its first frame to be complete.
    public static func isCompleteImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil,
              hasRequiredTerminalMarker(data) else {
            return false
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            return false
        }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            decodeOptions as CFDictionary
        ) else { return false }
        return decoded.width > 0 && decoded.height > 0
    }

    private static func hasRequiredTerminalMarker(_ data: Data) -> Bool {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.starts(with: pngSignature) {
            let iendChunk: [UInt8] = [
                0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
                0xAE, 0x42, 0x60, 0x82,
            ]
            return data.suffix(iendChunk.count).elementsEqual(iendChunk)
        }

        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            var end = data.endIndex
            while end > data.startIndex {
                let previous = data.index(before: end)
                if ![0x00, 0x09, 0x0A, 0x0D, 0x20].contains(data[previous]) {
                    break
                }
                end = previous
            }
            guard data.distance(from: data.startIndex, to: end) >= 2 else { return false }
            let last = data.index(before: end)
            let penultimate = data.index(before: last)
            return data[penultimate] == 0xFF && data[last] == 0xD9
        }

        if data.count >= 6,
           data.prefix(3).elementsEqual([0x47, 0x49, 0x46]) {
            return data.last == 0x3B
        }

        if data.count >= 12,
           data.prefix(4).elementsEqual([0x52, 0x49, 0x46, 0x46]),
           data[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            let declaredPayloadLength = Int(data[4])
                | (Int(data[5]) << 8)
                | (Int(data[6]) << 16)
                | (Int(data[7]) << 24)
            return declaredPayloadLength + 8 == data.count
        }

        return true
    }

    /// 诊断日志里说明一份封面数据为什么没被收下:大小、ImageIO 认出的类型和完整度、
    /// 头尾几个字节、结尾标记在不在、JPEG 最后一个结束标记后面还拖着多少字节
    /// (下载了半截与「完整的图后面多带了数据」靠这一项分开)。不解码整张图。
    public static func diagnosticSummary(_ data: Data) -> String {
        var parts = ["bytes=\(data.count)"]
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            parts.append("type=\(CGImageSourceGetType(source).map { $0 as String } ?? "nil")")
            parts.append("status=\(statusName(CGImageSourceGetStatus(source)))")
            if CGImageSourceGetCount(source) > 0 {
                parts.append("frame0=\(statusName(CGImageSourceGetStatusAtIndex(source, 0)))")
            }
        } else {
            parts.append("imageio=unreadable")
        }
        parts.append("head=\(hex(data.prefix(4))) tail=\(hex(data.suffix(4)))")
        parts.append("terminal=\(hasRequiredTerminalMarker(data))")
        if let trailing = trailingBytesAfterLastJPEGEnd(data) {
            parts.append("jpegTrailing=\(trailing)")
        }
        return parts.joined(separator: " ")
    }

    /// JPEG 里最后一个结束标记(FF D9)之后还有多少字节;不是 JPEG、或者一个结束标记
    /// 都没有(多半是下载断在中间)时返回 nil。
    public static func trailingBytesAfterLastJPEGEnd(_ data: Data) -> Int? {
        guard data.count >= 4, data[data.startIndex] == 0xFF,
              data[data.index(after: data.startIndex)] == 0xD8 else { return nil }
        var index = data.index(data.endIndex, offsetBy: -2)
        while index > data.startIndex {
            if data[index] == 0xFF, data[data.index(after: index)] == 0xD9 {
                return data.distance(from: data.index(index, offsetBy: 2), to: data.endIndex)
            }
            index = data.index(before: index)
        }
        return nil
    }

    private static func statusName(_ status: CGImageSourceStatus) -> String {
        switch status {
        case .statusComplete: "complete"
        case .statusIncomplete: "incomplete"
        case .statusReadingHeader: "readingHeader"
        case .statusUnknownType: "unknownType"
        case .statusInvalidData: "invalidData"
        case .statusUnexpectedEOF: "unexpectedEOF"
        @unknown default: "status\(status.rawValue)"
        }
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    public static func hasRedundantJPEGSampling(_ data: Data) -> Bool {
        guard data.count >= 12, data[0] == 0xFF, data[1] == 0xD8 else { return false }
        var marker = 2
        while marker + 3 < data.count {
            guard data[marker] == 0xFF else {
                marker += 1
                continue
            }
            while marker < data.count, data[marker] == 0xFF { marker += 1 }
            guard marker < data.count else { return false }
            let code = data[marker]
            marker += 1
            if code == 0xD9 || code == 0xDA { return false }
            if code == 0x01 || (0xD0...0xD7).contains(code) { continue }
            guard marker + 1 < data.count else { return false }
            let length = Int(data[marker]) << 8 | Int(data[marker + 1])
            guard length >= 2, marker + length <= data.count else { return false }

            if [0xC0, 0xC1, 0xC2].contains(code) {
                let payload = marker + 2
                guard payload + 6 <= data.count else { return false }
                let componentCount = Int(data[payload + 5])
                guard componentCount > 1,
                      payload + 6 + componentCount * 3 <= marker + length else {
                    return false
                }
                let samples = (0..<componentCount).map { data[payload + 7 + $0 * 3] }
                let hasRedundantSampling = samples.allSatisfy { $0 == samples[0] }
                    && samples[0] != 0x11
                return hasRedundantSampling && !isCompleteImage(data)
            }
            marker += length
        }
        return false
    }
}
