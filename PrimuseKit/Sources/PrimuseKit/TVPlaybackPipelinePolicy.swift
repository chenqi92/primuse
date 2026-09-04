import Foundation

/// Maps the logical timeline shown for a library row onto the physical media
/// timeline. CUE rows share one media file, so every seek and completion check
/// must include the segment's physical start offset.
public struct TVPlaybackSegment: Equatable, Sendable {
    public let physicalStart: TimeInterval
    public let physicalEnd: TimeInterval?
    public let logicalDuration: TimeInterval

    public init(
        cueStartTime: TimeInterval?,
        cueEndTime: TimeInterval?,
        storedDuration: TimeInterval
    ) {
        let start = cueStartTime.map { max(0, $0) } ?? 0
        let explicitEnd = cueEndTime.flatMap { value -> TimeInterval? in
            guard value.isFinite, value > start else { return nil }
            return value
        }
        let duration = storedDuration.isFinite ? max(0, storedDuration) : 0
        let derivedEnd: TimeInterval? = cueStartTime != nil && duration > 0
            ? start + duration
            : nil

        physicalStart = start
        physicalEnd = explicitEnd ?? derivedEnd
        logicalDuration = physicalEnd.map { max(0, $0 - start) } ?? duration
    }

    public var requiresInitialSeek: Bool { physicalStart > 0 }

    public func physicalTime(forLogicalTime value: TimeInterval) -> TimeInterval {
        let finite = value.isFinite ? value : 0
        let clamped = logicalDuration > 0
            ? min(max(0, finite), logicalDuration)
            : max(0, finite)
        return physicalStart + clamped
    }

    public func logicalTime(forPhysicalTime value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        let relative = max(0, value - physicalStart)
        return logicalDuration > 0 ? min(relative, logicalDuration) : relative
    }

    public func hasReachedPhysicalEnd(
        _ value: TimeInterval,
        tolerance: TimeInterval = 0.03
    ) -> Bool {
        guard value.isFinite, let physicalEnd else { return false }
        return value >= physicalEnd - max(0, tolerance)
    }
}

public enum TVPlaybackDelivery: Equatable, Sendable {
    case avPlayer(fileExtension: String)
    case decodedTemporaryFile(fileExtension: String, inspectWAVAfterDownload: Bool)
}

/// Keeps tvOS routing aligned with `AudioFormat` instead of maintaining a
/// second hand-written list. Subsonic-family WMA is the one intentional
/// exception because those resolvers return an MP3 transcode.
public enum TVPlaybackFormatRoutingPolicy {
    public static func delivery(
        for format: AudioFormat,
        isVideo: Bool,
        serverTranscodesWMA: Bool,
        wavProbeOutcome: RemoteWAVPlaybackPolicy.ProbeOutcome? = nil
    ) -> TVPlaybackDelivery {
        if isVideo {
            return .avPlayer(fileExtension: format.rawValue)
        }
        if format == .wma, serverTranscodesWMA {
            return .avPlayer(fileExtension: AudioFormat.mp3.rawValue)
        }
        if format == .wav {
            switch wavProbeOutcome {
            case .pcm:
                return .avPlayer(fileExtension: format.rawValue)
            case .dts:
                return .decodedTemporaryFile(
                    fileExtension: AudioFormat.dts.rawValue,
                    inspectWAVAfterDownload: false
                )
            case .unavailable:
                return .decodedTemporaryFile(
                    fileExtension: format.rawValue,
                    inspectWAVAfterDownload: true
                )
            case nil:
                return .avPlayer(fileExtension: format.rawValue)
            }
        }
        if format.requiresFFmpeg {
            return .decodedTemporaryFile(
                fileExtension: format.rawValue,
                inspectWAVAfterDownload: false
            )
        }
        return .avPlayer(fileExtension: format.rawValue)
    }
}

public struct TVHTTPRangeResponseValidation: Equatable, Sendable {
    public let totalLength: Int64?
    public let expectedBodyLength: Int64?
    public let supportsByteRanges: Bool

    public init(
        totalLength: Int64?,
        expectedBodyLength: Int64?,
        supportsByteRanges: Bool
    ) {
        self.totalLength = totalLength
        self.expectedBodyLength = expectedBodyLength
        self.supportsByteRanges = supportsByteRanges
    }
}

/// Validates response framing before bytes are associated with an AVFoundation
/// loading request. A 200 response cannot satisfy a non-zero byte offset.
public enum TVHTTPRangeResponsePolicy {
    public static func validate(
        statusCode: Int,
        contentRange: String?,
        contentLength: Int64?,
        contentEncoding: String?,
        requestedOffset: Int64,
        requestedLength: Int64,
        isLiveStream: Bool
    ) -> TVHTTPRangeResponseValidation? {
        guard requestedOffset >= 0 else { return nil }
        if isLiveStream {
            guard (200...299).contains(statusCode) else { return nil }
            let length = contentLength.flatMap { $0 >= 0 ? $0 : nil }
            return TVHTTPRangeResponseValidation(
                totalLength: length,
                expectedBodyLength: nil,
                supportsByteRanges: statusCode == 206
            )
        }

        let encoding = contentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard encoding == nil || encoding == "identity" else { return nil }

        if statusCode == 416,
           let total = parseUnsatisfiedContentRange(contentRange),
           requestedOffset >= total,
           contentLength == nil || contentLength == 0 {
            return TVHTTPRangeResponseValidation(
                totalLength: total,
                expectedBodyLength: 0,
                supportsByteRanges: true
            )
        }

        if statusCode == 206 {
            guard let parsed = parseContentRange(contentRange),
                  parsed.start == requestedOffset else { return nil }
            let expectedEnd: Int64
            if requestedLength > 0 {
                guard let exclusiveEnd = SafeByteRange.exclusiveEnd(
                    offset: requestedOffset,
                    length: requestedLength
                ), requestedOffset < parsed.total else { return nil }
                expectedEnd = min(exclusiveEnd, parsed.total) - 1
            } else {
                guard requestedOffset < parsed.total else { return nil }
                expectedEnd = parsed.total - 1
            }
            guard parsed.end == expectedEnd else { return nil }
            let expectedLength = parsed.end - parsed.start + 1
            if let contentLength, contentLength != expectedLength { return nil }
            return TVHTTPRangeResponseValidation(
                totalLength: parsed.total,
                expectedBodyLength: expectedLength,
                supportsByteRanges: true
            )
        }

        guard statusCode == 200, requestedOffset == 0 else { return nil }
        if requestedLength > 0 {
            guard let contentLength,
                  contentLength >= 0,
                  contentLength <= requestedLength else { return nil }
            return TVHTTPRangeResponseValidation(
                totalLength: contentLength,
                expectedBodyLength: contentLength,
                supportsByteRanges: false
            )
        }
        let wholeLength = contentLength.flatMap { $0 >= 0 ? $0 : nil }
        return TVHTTPRangeResponseValidation(
            totalLength: wholeLength,
            expectedBodyLength: wholeLength,
            supportsByteRanges: false
        )
    }

    private static func parseContentRange(
        _ header: String?
    ) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header else { return nil }
        let unitAndValue = header.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard unitAndValue.count == 2,
              unitAndValue[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              rangeAndTotal[1] != "*",
              let total = Int64(rangeAndTotal[1]),
              total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total else { return nil }
        return (start, end, total)
    }

    private static func parseUnsatisfiedContentRange(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let pieces = header.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard pieces.count == 2,
              pieces[0].lowercased() == "bytes",
              pieces[1].hasPrefix("*/"),
              let total = Int64(pieces[1].dropFirst(2)),
              total > 0 else { return nil }
        return total
    }
}

public enum TVDecodedDownloadStoragePolicy {
    public static let maximumFileSize: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let reservedCapacity: Int64 = 256 * 1_024 * 1_024

    public static func writableBudget(availableCapacity: Int64?) -> Int64 {
        guard let availableCapacity else { return maximumFileSize }
        return min(maximumFileSize, max(0, availableCapacity - reservedCapacity))
    }

    public static func accepts(contentLength: Int64, writableBudget: Int64) -> Bool {
        contentLength >= 0
            && contentLength <= maximumFileSize
            && contentLength <= max(0, writableBudget)
    }
}

/// Builds header sets for continuous radio requests and removes every
/// resolver-supplied header after a cross-endpoint redirect. Tokens are not
/// limited to `Authorization` (for example Plex and Emby use custom fields),
/// so treating all caller fields as sensitive is the safe boundary.
public enum TVRadioRequestHeaderPolicy {
    public static func merged(customHeaders: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in customHeaders
        where isValidFieldName(name) && isValidFieldValue(value) {
            let lowercased = name.lowercased()
            guard !["host", "connection", "content-length", "transfer-encoding", "range"]
                .contains(lowercased) else { continue }
            set(value, for: name, in: &result)
        }
        set("1", for: "Icy-MetaData", in: &result)
        if !contains("User-Agent", in: result) {
            set("Primuse/Radio", for: "User-Agent", in: &result)
        }
        set("identity", for: "Accept-Encoding", in: &result)
        return result
    }

    public static func strippingCustomHeaders(
        from request: URLRequest,
        customHeaderNames: [String]
    ) -> URLRequest {
        var result = request
        for name in customHeaderNames where isValidFieldName(name) {
            result.setValue(nil, forHTTPHeaderField: name)
        }
        let baseline = merged(customHeaders: [:])
        for (name, value) in baseline where result.value(forHTTPHeaderField: name) == nil {
            result.setValue(value, forHTTPHeaderField: name)
        }
        return result
    }

    private static func contains(_ field: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(field) == .orderedSame }
    }

    private static func set(
        _ value: String,
        for field: String,
        in headers: inout [String: String]
    ) {
        let duplicateKeys = headers.keys.filter {
            $0.caseInsensitiveCompare(field) == .orderedSame
        }
        for key in duplicateKeys {
            headers[key] = nil
        }
        headers[field] = value
    }

    private static func isValidFieldName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let tokenPunctuation = "!#$%&'*+-.^_`|~"
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || tokenPunctuation.unicodeScalars.contains(scalar)
            )
        }
    }

    private static func isValidFieldValue(_ value: String) -> Bool {
        !value.contains("\r") && !value.contains("\n") && !value.contains("\0")
    }
}

/// Applies the shared read-only media redirect policy to live radio while
/// treating every resolver-supplied field as a credential. Same-endpoint
/// redirects (including the policy's explicit HTTP-to-HTTPS upgrade) retain
/// those fields; CDN/object-store redirects receive only the radio baseline.
public enum TVRadioRedirectRequestPolicy {
    public static let maximumRedirects = HTTPMediaRedirectRequestPolicy.maximumRedirects

    public static func redirectedRequest(
        from original: URLRequest,
        response: HTTPURLResponse,
        customHeaders: [String: String]
    ) -> URLRequest? {
        guard let sourceURL = response.url ?? original.url,
              let redirected = HTTPMediaRedirectRequestPolicy.redirectedRequest(
                  from: original,
                  response: response
              ),
              let destinationURL = redirected.url else {
            return nil
        }
        guard !HTTPRedirectSecurityPolicy.allows(
            from: sourceURL,
            to: destinationURL
        ) else {
            return redirected
        }
        return TVRadioRequestHeaderPolicy.strippingCustomHeaders(
            from: redirected,
            customHeaderNames: Array(customHeaders.keys)
        )
    }
}
