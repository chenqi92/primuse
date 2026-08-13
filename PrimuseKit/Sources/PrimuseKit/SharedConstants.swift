import Foundation
import CoreFoundation
import CryptoKit

/// Reconciles the local and synchronizable Keychain variants used for cloud
/// OAuth credentials. A rotation is durable only when no obsolete variant can
/// later surface the previous refresh token.
public enum CloudCredentialVariantPolicy {
    /// The target write may be reported as persisted only after the obsolete
    /// variant is gone, has been made an exact mirror, or is a synchronizable
    /// item that this process cannot access and therefore cannot read back.
    public static func isWriteSafe(
        targetStored: Bool,
        obsoleteVariantRemoved: Bool,
        obsoleteVariantMatchesTarget: Bool,
        obsoleteVariantCannotOverrideTarget: Bool
    ) -> Bool {
        targetStored && (
            obsoleteVariantRemoved
                || obsoleteVariantMatchesTarget
                || obsoleteVariantCannotOverrideTarget
        )
    }

    /// When both variants exist during launch migration, modification dates
    /// decide which copy is authoritative. Ties or missing metadata keep the
    /// synchronizable value so a residual legacy/local item can never roll a
    /// newer roaming refresh token back.
    public static func shouldReplaceSynchronizableValue(
        localModifiedAt: Date?,
        synchronizableModifiedAt: Date?
    ) -> Bool {
        guard let localModifiedAt, let synchronizableModifiedAt else { return false }
        return localModifiedAt > synchronizableModifiedAt
    }
}

/// Builds deterministic, collision-resistant filenames for remote-file caches.
/// The remote path is hashed instead of replacing separators, because paths such
/// as `/A/B.mp3` and `/A_B.mp3` must never address the same cached bytes.
public enum CacheFileNamePolicy {
    public static func make(
        path: String,
        preferredExtension: String? = nil
    ) -> String {
        let normalizedPath = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let pathExtension = (path as NSString).pathExtension
        let ext = normalizedExtension(preferredExtension) ?? normalizedExtension(pathExtension)
        return ext.map { "\(hash).\($0)" } ?? hash
    }

    /// The pre-hash filename remains useful only for deleting stale cache files
    /// written by older builds. It must never be used as a current cache key.
    public static func legacySanitized(path: String) -> String {
        path.replacingOccurrences(of: "/", with: "_")
    }

    private static func normalizedExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return normalized
    }
}

/// Gives an opaque provider item ID a media extension for decoder sniffing.
/// The returned path is only a type hint; connectors continue to fetch bytes
/// with the original provider path.
public enum MediaDecodingPathPolicy {
    public static func make(path: String, preferredExtension: String?) -> String {
        guard (path as NSString).pathExtension.isEmpty,
              let preferredExtension else { return path }
        let normalized = preferredExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return path }
        return "\(path).\(normalized)"
    }
}

/// Distinguishes retryable OAuth token-endpoint failures from credentials that
/// are definitively unusable. Callers must not delete or merge account data
/// merely because a provider is temporarily unavailable.
public enum CloudTokenRefreshFailureDisposition: Sendable {
    case transient
    case permanent
}

public enum CloudTokenRefreshPolicy {
    public static func disposition(
        statusCode: Int?,
        providerErrorCode: String? = nil
    ) -> CloudTokenRefreshFailureDisposition {
        let normalizedError = providerErrorCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let transientErrors: Set<String> = [
            "temporarily_unavailable", "server_error", "slow_down",
            "rate_limited", "rate_limit_exceeded", "too_many_requests",
        ]
        if let normalizedError, transientErrors.contains(normalizedError) {
            return .transient
        }

        if let statusCode,
           statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
            return .transient
        }

        return .permanent
    }
}

/// Encodes Foundation-style JSON objects without calling
/// `JSONSerialization.data(withJSONObject:)`.
///
/// The Objective-C writer can raise an `NSException` while bridging Swift
/// collections. `NSException` bypasses Swift `do/catch`, so callers cannot
/// recover even when they use `try` or `try?`. Converting the supported JSON
/// graph to an `Encodable` value first keeps failures in Swift's error model.
public enum SafeJSONSerialization {
    public static func data(
        withJSONObject object: Any,
        options: JSONSerialization.WritingOptions = []
    ) throws -> Data {
        let value = try JSONValue(object)
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if options.contains(.prettyPrinted) { formatting.insert(.prettyPrinted) }
        if options.contains(.sortedKeys) { formatting.insert(.sortedKeys) }
        if options.contains(.withoutEscapingSlashes) { formatting.insert(.withoutEscapingSlashes) }
        encoder.outputFormatting = formatting
        return try encoder.encode(value)
    }

    public struct UnsupportedValueError: LocalizedError, Sendable {
        public let typeName: String

        public var errorDescription: String? {
            PMString("error.json.unsupportedType", typeName)
        }
    }

    private enum JSONValue: Encodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case signedInteger(Int64)
        case unsignedInteger(UInt64)
        case number(Double)
        case bool(Bool)
        case null

        init(_ rawValue: Any) throws {
            let mirror = Mirror(reflecting: rawValue)
            if mirror.displayStyle == .optional {
                if let wrapped = mirror.children.first?.value {
                    self = try JSONValue(wrapped)
                } else {
                    self = .null
                }
                return
            }

            if rawValue is NSNull {
                self = .null
                return
            }

            // Swift numeric values bridge to NSNumber. Inspect the Core
            // Foundation type first because NSNumber(1) also casts to Bool.
            if let number = rawValue as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                    return
                }
                let encoding = String(cString: number.objCType)
                switch encoding {
                case "C", "S", "I", "L", "Q":
                    self = .unsignedInteger(number.uint64Value)
                case "f", "d":
                    let value = number.doubleValue
                    guard value.isFinite else {
                        throw UnsupportedValueError(typeName: "non-finite number")
                    }
                    self = .number(value)
                default:
                    self = .signedInteger(number.int64Value)
                }
                return
            }

            if let string = rawValue as? String {
                self = .string(string)
                return
            }
            if let dictionary = rawValue as? [String: Any] {
                self = .object(try dictionary.mapValues(JSONValue.init))
                return
            }
            if let array = rawValue as? [Any] {
                self = .array(try array.map(JSONValue.init))
                return
            }
            if let dictionary = rawValue as? NSDictionary {
                var result: [String: JSONValue] = [:]
                for (key, value) in dictionary {
                    guard let key = key as? String else {
                        throw UnsupportedValueError(typeName: "non-string dictionary key")
                    }
                    result[key] = try JSONValue(value)
                }
                self = .object(result)
                return
            }
            if let array = rawValue as? NSArray {
                self = .array(try array.map(JSONValue.init))
                return
            }

            throw UnsupportedValueError(typeName: String(reflecting: type(of: rawValue)))
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .object(let values):
                var container = encoder.container(keyedBy: JSONKey.self)
                for (key, value) in values {
                    try container.encode(value, forKey: JSONKey(key))
                }
            case .array(let values):
                var container = encoder.unkeyedContainer()
                for value in values { try container.encode(value) }
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .signedInteger(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .unsignedInteger(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .number(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .bool(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }

    private struct JSONKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }
}

public extension BinaryFloatingPoint {
    /// Converts a floating-point value to `Int` without allowing malformed
    /// metadata (`NaN`, infinity, or an out-of-range finite value) to trap.
    /// Callers can choose a domain-appropriate fallback; durations normally
    /// use zero so an invalid value is treated as unknown.
    func finiteInt(or fallback: Int = 0) -> Int {
        let value = Double(self)
        guard value.isFinite,
              value >= Double(Int.min),
              value < Double(Int.max) else {
            return fallback
        }
        return Int(value)
    }

    /// Converts a floating-point value to `UInt64` without trapping on
    /// negative, non-finite, or out-of-range timeout/configuration values.
    func finiteUInt64(or fallback: UInt64 = 0) -> UInt64 {
        let value = Double(self)
        guard value.isFinite,
              value >= 0,
              value < Double(UInt64.max) else {
            return fallback
        }
        return UInt64(value)
    }
}

public extension FileManager {
    /// Search-path APIs normally return one URL on Apple platforms, but using
    /// `.first!` turns an unusual container/filesystem failure into a process
    /// trap. Temporary storage is a safe last-resort location for startup.
    func primuseDirectoryURL(for directory: SearchPathDirectory) -> URL {
        urls(for: directory, in: .userDomainMask).first ?? temporaryDirectory
    }
}

/// Resolves an absolute file path persisted inside an older iOS app-data
/// container. Reinstalling an app changes the container UUID while restored
/// Application Support, Caches and Documents content keeps the same relative
/// location. Only known Primuse-owned roots are rebased, and a URL is returned
/// only when the direct or rebased target exists.
public enum PrimuseSandboxPathResolver {
    public static func existingURL(
        forStoredAbsolutePath storedPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard storedPath.hasPrefix("/") else { return nil }

        let directURL = URL(fileURLWithPath: storedPath).standardizedFileURL
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let roots: [(marker: String, currentRoot: URL)] = [
            (
                "/Library/Application Support/Primuse/",
                fileManager
                    .primuseDirectoryURL(for: .applicationSupportDirectory)
                    .appendingPathComponent("Primuse", isDirectory: true)
            ),
            (
                "/Library/Caches/Primuse/",
                fileManager
                    .primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("Primuse", isDirectory: true)
            ),
            (
                "/Documents/LocalMusic/",
                fileManager
                    .primuseDirectoryURL(for: .documentDirectory)
                    .appendingPathComponent("LocalMusic", isDirectory: true)
            ),
        ]

        for root in roots {
            guard let markerRange = storedPath.range(of: root.marker) else { continue }
            let relativePath = String(storedPath[markerRange.upperBound...])
            let standardizedRoot = root.currentRoot.standardizedFileURL
            let candidate = relativePath.isEmpty
                ? standardizedRoot
                : standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
            let rootPrefix = standardizedRoot.path.hasSuffix("/")
                ? standardizedRoot.path
                : standardizedRoot.path + "/"
            guard (candidate.path == standardizedRoot.path || candidate.path.hasPrefix(rootPrefix)),
                  fileManager.fileExists(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }
}

public enum SafeByteRange {
    /// Returns the exclusive end for a non-negative byte range, or `nil`
    /// when the range is empty, negative, or would overflow `Int64`.
    public static func exclusiveEnd(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end > offset else { return nil }
        return end
    }

    /// RFC 7233 Range header. Negative offsets use suffix-range syntax.
    public static func httpHeader(offset: Int64, length: Int64) -> String? {
        guard length > 0 else { return nil }
        if offset < 0 { return "bytes=\(offset)" }
        guard let end = exclusiveEnd(offset: offset, length: length) else { return nil }
        return "bytes=\(offset)-\(end - 1)"
    }
}

/// A two-byte probe avoids a MiniDLNA 1.3.3 edge case where `bytes=0-0`
/// is treated as an open-ended request and the whole file is streamed. The
/// response must also describe exactly the requested (or EOF-clipped) range;
/// a bare 206 is not sufficient proof that later random access is safe.
public enum HTTPRangeProbePolicy {
    public static let requestHeaderValue = "bytes=0-1"

    public static func validatedTotalLength(
        contentRange header: String?,
        contentLength: Int64?
    ) -> Int64? {
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
              start == 0,
              end == min(1, total - 1) else { return nil }

        let expectedLength = min(Int64(2), total)
        if let contentLength, contentLength != expectedLength {
            return nil
        }
        return total
    }
}

/// Validates one HTTP 206 response before its bytes enter a sparse audio cache.
/// A status code alone is insufficient: proxies can return the wrong window,
/// expand a request to the full resource, or compress the body while keeping
/// byte-oriented headers from the origin.
public enum HTTPByteRangeResponsePolicy {
    public static func validatedTotalLength(
        contentRange header: String?,
        contentLength: Int64?,
        bodyLength: Int,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Int64? {
        guard requestedLength > 0, bodyLength >= 0, let parsed = parse(header) else {
            return nil
        }

        let expectedStart: Int64
        let expectedEnd: Int64
        if requestedOffset >= 0 {
            guard requestedOffset < parsed.total,
                  let exclusiveEnd = SafeByteRange.exclusiveEnd(
                      offset: requestedOffset,
                      length: requestedLength
                  ) else { return nil }
            expectedStart = requestedOffset
            expectedEnd = min(exclusiveEnd, parsed.total) - 1
        } else {
            guard requestedOffset != Int64.min else { return nil }
            let suffixLength = -requestedOffset
            expectedStart = max(0, parsed.total - suffixLength)
            expectedEnd = parsed.total - 1
        }

        let expectedLength = expectedEnd - expectedStart + 1
        guard parsed.start == expectedStart,
              parsed.end == expectedEnd,
              Int64(bodyLength) == expectedLength else { return nil }
        if let contentLength, contentLength != expectedLength { return nil }
        return parsed.total
    }

    /// A server that ignores Range may still safely satisfy a request when the
    /// entire resource is no larger than the requested head/suffix window.
    public static func acceptsWholeResourceResponse(
        bodyLength: Int,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Bool {
        guard bodyLength >= 0, requestedLength > 0 else { return false }
        if requestedOffset == 0 {
            return Int64(bodyLength) <= requestedLength
        }
        if requestedOffset < 0, requestedOffset != Int64.min {
            return Int64(bodyLength) <= -requestedOffset
        }
        return false
    }

    private static func parse(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
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
}

/// Extracts a metadata-only byte window when a WebDAV proxy ignores `Range`
/// and returns the complete resource with HTTP 200.
///
/// This must not be used by sparse playback caches: a whole-resource response
/// cannot prove that later random-access reads are safe. Metadata readers are
/// different — they only need a bounded head or tail slice and never place the
/// result at an arbitrary offset in the playback cache.
public enum WholeResourceMetadataRangePolicy {
    public static func sliceRange(
        bodyLength: Int,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> Range<Int>? {
        guard bodyLength > 0,
              requestedLength > 0,
              requestedOffset != Int64.min else {
            return nil
        }

        let totalLength = Int64(bodyLength)
        let start = requestedOffset < 0
            ? max(0, totalLength + requestedOffset)
            : requestedOffset
        guard start >= 0,
              start < totalLength,
              let requestedEnd = SafeByteRange.exclusiveEnd(
                offset: start,
                length: requestedLength
              ) else {
            return nil
        }

        let end = min(requestedEnd, totalLength)
        return Int(start)..<Int(end)
    }
}

public enum AudioChannelConversionPolicy {
    public static func requiresDownmix(
        sourceChannelCount: Int,
        outputChannelCount: Int
    ) -> Bool {
        sourceChannelCount > outputChannelCount && outputChannelCount > 0
    }
}

/// A remote `.wav` row can predate DTS-CD content classification. In that
/// case the carrier still looks like ordinary PCM to the native range decoder,
/// so an unavailable probe must fail safe to a complete-file decode path.
public enum RemoteWAVPlaybackPolicy {
    public enum ProbeOutcome: Sendable, Equatable {
        case pcm
        case dts
        case unavailable
    }

    public static func requiresCompleteFile(
        persistedFormat: AudioFormat,
        probeOutcome: ProbeOutcome
    ) -> Bool {
        guard persistedFormat == .wav else { return false }
        return probeOutcome != .pcm
    }
}

/// Some connectors cannot safely sustain the generic five-request playback
/// burst. OneDrive can stall under concurrent ranges, while FilesProvider's FTP
/// range implementation leaves each control task open until its session is
/// invalidated. Both use demand-driven reads instead of background prefetch.
public enum RangeStreamingPrefetchPolicy {
    public enum BackgroundCacheMode: Sendable, Equatable {
        case disabled
        case rangePrewarm
        case completeFile
    }

    public static func aheadCount(
        for sourceType: MusicSourceType,
        defaultValue: Int
    ) -> Int {
        switch sourceType {
        case .oneDrive, .ftp:
            return 0
        case .webdav, .synology:
            return min(1, max(0, defaultValue))
        default:
            return max(0, defaultValue)
        }
    }

    /// Complete downloads for these connectors must use one sequential
    /// transfer. Repeating random-access requests is especially expensive when
    /// a WebDAV proxy ignores Range and returns the entire file for every chunk.
    public static func usesSingleTransferForCompleteDownload(
        for sourceType: MusicSourceType
    ) -> Bool {
        switch sourceType {
        case .webdav, .synology, .jellyfin, .emby, .plex:
            return true
        default:
            return false
        }
    }

    public static func allowsBackgroundPrewarm(for sourceType: MusicSourceType) -> Bool {
        allowsAutomaticTrailingFill(for: sourceType)
    }

    /// Selects the cache work for one queued track. A source can advertise
    /// Range reads while the file format itself still requires a complete,
    /// seekable local file (for example DTS through FFmpeg). Those tracks must
    /// be materialized instead of falling through the Range branch without
    /// doing any work.
    public static func backgroundCacheMode(
        cacheEnabled: Bool,
        supportsRangeStreaming: Bool,
        hasKnownFileSize: Bool,
        usesRangeStreamingForPlayback: Bool,
        requiresCompleteLocalFile: Bool
    ) -> BackgroundCacheMode {
        guard cacheEnabled else { return .disabled }
        guard supportsRangeStreaming, hasKnownFileSize else { return .completeFile }
        if usesRangeStreamingForPlayback { return .rangePrewarm }
        if requiresCompleteLocalFile { return .completeFile }
        return .disabled
    }

    /// Whether a foreground range read may schedule completion of the
    /// remaining cache gap in the background. Constrained connectors must
    /// stay demand-driven even when the remaining file is below the generic
    /// trailing-fill threshold.
    public static func allowsAutomaticTrailingFill(for sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .oneDrive, .ftp, .webdav, .synology:
            return false
        default:
            return true
        }
    }
}

/// Constrains persisted remote paths to one canonical source root. Protocol
/// connectors use this before reads and destructive operations so stale or
/// tampered absolute paths cannot escape the source that owns them.
public struct RemotePathScopePolicy: Equatable, Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = Self.normalizeAbsolutePath(rootPath)
    }

    /// Resolves a stored absolute or source-relative path and rejects any path
    /// that can escape the configured root. Parent components are rejected
    /// before standardization so a persisted `..` can never be hidden by a
    /// later in-root component.
    public func resolvedPath(forStoredPath storedPath: String) -> String? {
        guard !Self.containsParentReference(storedPath) else { return nil }
        if storedPath.isEmpty || storedPath == "/" { return rootPath }

        let candidate: String
        if storedPath.hasPrefix("/") {
            candidate = Self.normalizeAbsolutePath(storedPath)
        } else if rootPath == "/" {
            candidate = Self.normalizeAbsolutePath("/\(storedPath)")
        } else {
            candidate = Self.normalizeAbsolutePath("\(rootPath)/\(storedPath)")
        }

        guard rootPath == "/"
                || candidate == rootPath
                || candidate.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    /// Converts a validated stored path to a slash-prefixed path relative to
    /// the configured root. This is the namespace expected by mounted NFS
    /// clients, whose `/` is already the selected export.
    public func relativePath(forStoredPath storedPath: String) -> String? {
        guard let resolved = resolvedPath(forStoredPath: storedPath) else { return nil }
        guard rootPath != "/" else { return resolved }
        guard resolved != rootPath else { return "/" }
        return String(resolved.dropFirst(rootPath.count))
    }

    /// Export identities must match exactly. Component-prefix collisions such
    /// as `/exports/music-old` are not children of `/exports/music` and a
    /// stored parent reference is never accepted as an alias of the same root.
    public func matchesRoot(_ storedRoot: String) -> Bool {
        guard !Self.containsParentReference(storedRoot) else { return false }
        return Self.normalizeAbsolutePath(storedRoot) == rootPath
    }

    private static func containsParentReference(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." }
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let absolutePath = path.hasPrefix("/") ? path : "/\(path)"
        var normalized = (absolutePath as NSString).standardizingPath
        if normalized.isEmpty || normalized == "." { return "/" }
        if !normalized.hasPrefix("/") { normalized = "/\(normalized)" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

public struct NFSScopedSelection: Equatable, Sendable {
    public let exportPath: String
    public let relativePath: String

    public init(exportPath: String, relativePath: String) {
        self.exportPath = exportPath
        self.relativePath = relativePath
    }
}

/// Validates the decoded parts of an NFS selection path before a client mounts
/// an export. A configured source is confined to that exact export; all sources
/// reject parent components in both the export identity and relative file path.
public enum NFSSelectionScopePolicy {
    public static func resolve(
        exportPath: String,
        relativePath: String,
        configuredExportPath: String?
    ) -> NFSScopedSelection? {
        let exportScope = RemotePathScopePolicy(rootPath: exportPath)
        guard exportScope.matchesRoot(exportPath),
              let scopedRelativePath = RemotePathScopePolicy(rootPath: "/")
                .resolvedPath(forStoredPath: relativePath) else {
            return nil
        }

        if let configuredExportPath {
            let configured = configuredExportPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty {
                let configuredScope = RemotePathScopePolicy(rootPath: configured)
                guard configuredScope.matchesRoot(configured),
                      configuredScope.matchesRoot(exportScope.rootPath) else {
                    return nil
                }
            }
        }

        return NFSScopedSelection(
            exportPath: exportScope.rootPath,
            relativePath: scopedRelativePath
        )
    }
}

/// Keeps WebDAV response paths in the source-relative namespace even when a
/// reverse proxy exposes the upstream `/dav` root under a longer public path.
/// Some servers return upstream hrefs in PROPFIND responses, while clients
/// resolve operations against the configured public base URL.
public struct WebDAVPathPolicy: Equatable, Sendable {
    public let basePath: String

    public init(basePath: String?) {
        self.basePath = Self.normalizeAbsolutePath(basePath ?? "/")
    }

    /// Converts an absolute server href/path to a source-relative path. The
    /// full configured root is preferred; its final component is also accepted
    /// for reverse proxies that expose an upstream WebDAV root such as `/dav`
    /// without rewriting XML response bodies.
    public func sourcePath(forServerPath serverPath: String) -> String? {
        let decodedPath = serverPath.removingPercentEncoding ?? serverPath
        guard decodedPath.hasPrefix("/"),
              !Self.containsParentReference(decodedPath) else {
            return nil
        }

        let targetPath = Self.normalizeAbsolutePath(decodedPath)
        guard basePath != "/" else { return targetPath }

        var candidateRoots = [basePath]
        if let leaf = basePath.split(separator: "/").last {
            let upstreamRoot = "/\(leaf)"
            if upstreamRoot != basePath {
                candidateRoots.append(upstreamRoot)
            }
        }
        for candidateRoot in candidateRoots {
            if targetPath == candidateRoot {
                return "/"
            }
            if targetPath.hasPrefix(candidateRoot + "/") {
                return String(targetPath.dropFirst(candidateRoot.count))
            }
        }
        return nil
    }

    /// Converts FilesProvider's callback path to the source-relative namespace.
    /// FilesProvider normally strips the configured base path before creating a
    /// FileObject, while reverse-proxy responses can still retain the upstream
    /// WebDAV root. Prefer the server-path mapping for that retained-root case,
    /// then accept the already-relative callback path without prefixing the
    /// configured base path a second time.
    public func sourcePath(forProviderPath providerPath: String) -> String? {
        if let sourcePath = sourcePath(forServerPath: providerPath) {
            return sourcePath
        }
        let decodedPath = providerPath.removingPercentEncoding ?? providerPath
        return RemotePathScopePolicy(rootPath: "/")
            .resolvedPath(forStoredPath: decodedPath)
    }

    private static func containsParentReference(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." }
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let absolutePath = path.hasPrefix("/") ? path : "/\(path)"
        var normalized = (absolutePath as NSString).standardizingPath
        if normalized.isEmpty || normalized == "." { return "/" }
        if !normalized.hasPrefix("/") { normalized = "/\(normalized)" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

/// Keeps the app-facing FTP namespace relative to the configured source root.
/// FilesProvider must receive a root base URL because it applies its own
/// `ftpPath` helper more than once in several operations; putting `basePath` in
/// both the URL and operation path would produce `/base/base/...` commands.
public struct FTPPathPolicy: Equatable, Sendable {
    public static let providerBaseURLPath = "/"

    public let basePath: String

    public init(basePath: String?) {
        self.basePath = Self.normalizeAbsolutePath(basePath ?? "/")
    }

    /// Converts a source-relative browser/song path to the absolute server path
    /// passed to every FilesProvider operation.
    public func providerPath(forSourcePath sourcePath: String) -> String {
        let sourcePath = Self.normalizeAbsolutePath(sourcePath)
        guard basePath != "/" else { return sourcePath }
        guard sourcePath != "/" else { return basePath }
        return basePath + sourcePath
    }

    /// Converts a FilesProvider list result back to the source-relative path
    /// persisted by selected directories and songs. Out-of-root results are
    /// rejected instead of escaping the configured source scope.
    public func sourcePath(forProviderPath providerPath: String) -> String? {
        let providerPath = Self.normalizeAbsolutePath(providerPath)
        guard basePath != "/" else { return providerPath }
        if providerPath == basePath { return "/" }
        guard providerPath.hasPrefix(basePath + "/") else { return nil }
        return String(providerPath.dropFirst(basePath.count))
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let absolutePath = path.hasPrefix("/") ? path : "/\(path)"
        var normalized = (absolutePath as NSString).standardizingPath
        if normalized.isEmpty || normalized == "." { return "/" }
        if !normalized.hasPrefix("/") { normalized = "/\(normalized)" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

/// Keeps FTP callback quirks from turning an incomplete transfer into a
/// durable cache entry. FilesProvider can invoke a completion more than once
/// while validating the final control reply; its additional MLST fallback
/// callback source is disabled below.
public enum FTPTransferPolicy {
    /// FilesProvider 0.26's MLST fallback calls its attribute completion twice.
    /// Its RETR path starts a transfer for both callbacks, so callers that add
    /// their own retry must use the dependency's single-callback LIST path.
    public static let usesRFC3659ForAttributes = false

    public enum CallbackDecision: Equatable, Sendable {
        case accept
        case retry
        case awaitRetry
        case fail
    }

    public enum PromotionDecision: Equatable, Sendable {
        case rejectTemporary
        case useExistingTarget
        case promoteTemporary
        case replaceIncompleteTarget
    }

    public struct RangePlan: Equatable, Sendable {
        public let offset: Int64
        public let expectedLength: Int

        public init(offset: Int64, expectedLength: Int) {
            self.offset = offset
            self.expectedLength = expectedLength
        }
    }

    /// A full-file callback is valid only when the transport itself succeeded
    /// and the staged file has the exact advertised byte count. This matters
    /// for zero-byte files because a failed transfer may still leave an empty
    /// destination behind.
    public static func downloadPayloadIsValid(
        expectedSize: Int64,
        actualSize: Int64?,
        errorOccurred: Bool
    ) -> Bool {
        !errorOccurred && expectedSize >= 0 && actualSize == expectedSize
    }

    /// Converts regular and suffix requests into a nonnegative, EOF-clipped
    /// range whose expected byte count fits FilesProvider's `Int` API.
    public static func rangePlan(
        fileSize: Int64,
        requestedOffset: Int64,
        requestedLength: Int64
    ) -> RangePlan {
        let safeFileSize = max(0, fileSize)
        let actualOffset = requestedOffset < 0
            ? max(0, safeFileSize + requestedOffset)
            : requestedOffset
        let available = actualOffset < safeFileSize
            ? safeFileSize - actualOffset
            : 0
        let boundedLength = min(
            max(0, requestedLength),
            min(available, Int64(Int.max))
        )
        return RangePlan(offset: actualOffset, expectedLength: Int(boundedLength))
    }

    /// A positive range is complete only when its callback contains every
    /// EOF-clipped byte and no transport error accompanied the buffer.
    public static func rangePayloadIsValid(
        expectedLength: Int,
        actualLength: Int?,
        errorOccurred: Bool
    ) -> Bool {
        !errorOccurred && expectedLength >= 0 && actualLength == expectedLength
    }

    /// A valid payload from either attempt wins. The first failed callback
    /// starts one retry; duplicate callbacks from that first attempt are
    /// ignored while the retry is active.
    public static func callbackDecision(
        attempt: Int,
        payloadIsValid: Bool,
        retryAlreadyStarted: Bool
    ) -> CallbackDecision {
        if payloadIsValid { return .accept }
        if attempt == 0 {
            return retryAlreadyStarted ? .awaitRetry : .retry
        }
        return .fail
    }

    /// FTP is byte-preserving in binary mode, so only an exact byte count may
    /// be promoted. If another concurrent request already installed an exact
    /// target, that target wins and the redundant temporary file is discarded.
    public static func promotionDecision(
        expectedSize: Int64,
        temporarySize: Int64?,
        existingTargetSize: Int64?
    ) -> PromotionDecision {
        guard expectedSize >= 0, temporarySize == expectedSize else {
            return .rejectTemporary
        }
        if existingTargetSize == expectedSize {
            return .useExistingTarget
        }
        if existingTargetSize != nil {
            return .replaceIncompleteTarget
        }
        return .promoteTemporary
    }
}

/// Resolves a callback/cancellation race exactly once, including cancellation
/// that arrives before the checked continuation has been installed.
public final class CancellableResultRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var resolved = false

    public init() {}

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    public func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    public func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    @discardableResult
    public func cancel() -> Bool {
        resolve(.failure(CancellationError()))
    }
}

/// A one-shot bag for transport resources that may be installed concurrently
/// with termination. Resources already present are cancelled by `cancelAll`;
/// resources registered after termination are cancelled immediately.
public final class OneShotCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []
    private var terminated = false

    public init() {}

    /// Returns `true` when the action was retained for later cancellation and
    /// `false` when termination had already happened and it ran immediately.
    @discardableResult
    public func register(_ action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            action()
            return false
        }
        actions.append(action)
        lock.unlock()
        return true
    }

    @discardableResult
    public func cancelAll() -> Int {
        lock.lock()
        terminated = true
        let pending = actions
        actions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
        return pending.count
    }
}

/// Thread-safe cancellation registry used when one logical connector owns
/// several isolated transport sessions. `cancelAll` takes the actions before
/// invoking them so callbacks may unregister themselves without deadlocking.
public final class CancellableOperationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    @discardableResult
    public func register(_ action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        actions[id] = action
        lock.unlock()
        return id
    }

    public func unregister(_ id: UUID) {
        lock.lock()
        actions[id] = nil
        lock.unlock()
    }

    @discardableResult
    public func cancelAll() -> Int {
        lock.lock()
        let pending = Array(actions.values)
        actions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
        return pending.count
    }
}

/// Owns cancellable operations for exactly one connection generation.
/// Closing a generation forms a latch: registrations that race or arrive
/// afterward are cancelled immediately, while a stale close cannot affect a
/// newer connection.
public final class ConnectionScopedOperationRegistry: @unchecked Sendable {
    public struct Generation: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: Generation?
    private var actions: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Opens a fresh generation and cancels any operations left behind by a
    /// previous generation before returning its token.
    @discardableResult
    public func open() -> Generation {
        lock.lock()
        nextGeneration &+= 1
        let generation = Generation(value: nextGeneration)
        activeGeneration = generation
        let stale = Array(actions.values)
        actions.removeAll()
        lock.unlock()
        stale.forEach { $0() }
        return generation
    }

    /// Returns an ID only when the supplied generation is still open. A
    /// rejected registration is cancelled synchronously and is never retained.
    @discardableResult
    public func register(
        for generation: Generation,
        _ action: @escaping @Sendable () -> Void
    ) -> UUID? {
        let id = UUID()
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            action()
            return nil
        }
        actions[id] = action
        lock.unlock()
        return id
    }

    public func unregister(_ id: UUID) {
        lock.lock()
        actions[id] = nil
        lock.unlock()
    }

    public func isActive(_ generation: Generation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    /// Closes only the matching generation. Every retained operation is
    /// cancelled exactly once; later registrations for that token cancel
    /// themselves immediately.
    @discardableResult
    public func close(_ generation: Generation) -> Int {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return 0
        }
        activeGeneration = nil
        let pending = Array(actions.values)
        actions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
        return pending.count
    }

    public var activeOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }
}

public enum PrimuseConstants {
    public static let appGroupIdentifier = "group.com.welape.yuanyin"
    public static let playbackStateKey = "playbackState"
    public static let keychainServiceName = "com.welape.primuse.credentials"

    // Widget shared snapshots (App Group). Written by the main app, read by
    // the WidgetKit extension. Keys also double as the @AppStorage keys the
    // settings UI binds to (sync toggle / refresh mode) so both sides agree.
    public static let lyricsSnapshotKey = "widget.lyricsSnapshot"
    public static let listeningStatsKey = "widget.listeningStats"
    public static let sourcesSnapshotKey = "widget.sourcesSnapshot"
    public static let wrappedSnapshotKey = "widget.wrappedSnapshot"
    public static let widgetSyncEnabledKey = "widget.syncEnabled"
    public static let widgetRefreshModeKey = "widget.refreshMode"
    public static let widgetSharedDataScopeKey = "widget.sharedDataScope"
    public static let widgetClickableInteractionKey = "widget.clickableInteraction"
    public static let widgetNowPlayingEnabledKey = "widget.enabled.nowPlaying"
    public static let widgetLyricsEnabledKey = "widget.enabled.lyrics"
    public static let widgetListeningStatsEnabledKey = "widget.enabled.listeningStats"
    public static let widgetRecentAlbumsEnabledKey = "widget.enabled.recentAlbums"
    public static let widgetSourcesEnabledKey = "widget.enabled.sources"
    public static let widgetWrappedEnabledKey = "widget.enabled.wrapped"

    public static let eqBandFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    public static let eqBandCount = 10
    public static let eqMinGain: Float = -12.0
    public static let eqMaxGain: Float = 12.0
    public static let eqDefaultBandwidth: Float = 1.0

    public static let defaultCacheSizeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
    public static let smallFileThreshold: Int64 = 50 * 1024 * 1024 // 50 MB

    public static let supportedCoverExtensions = ["jpg", "jpeg", "png", "webp"]
    public static let supportedLyricsExtensions = ["lrc", "ttml"]
    public static let supportedMusicVideoExtensions = ["mp4", "m4v", "mov"]
    public static let supportedStreamDescriptorExtensions: Set<String> = ["strm"]
    public static let folderCoverNames = ["cover", "folder", "album", "front", "artwork"]

    /// Note: `.mp4` is intentionally excluded — it's primarily a video
    /// container, and the SFB AAC-in-MP4 decoder is unreliable for the
    /// kind of mp4 a user typically drops in their music folder (often
    /// extracted-from-video files with non-standard atom layout). Audio
    /// MP4 files should use `.m4a`. Including `.mp4` here led to mid-stream
    /// PCM decode errors that auto-skipped 25%+ of cloud-drive scans.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "au", "snd", "caf", "alac",
        "ape", "dsf", "dff", "ogg", "opus", "wma", "asf", "wv", "dts", "dtshd", "dts-hd",
        "ac3", "eac3", "ec3", "mlp", "truehd", "thd", "amr", "awb",
        "atrac", "oma", "aa3", "at3", "tak", "tta", "mpc", "mpp", "shn", "speex", "spx", "qoa"
    ]

    /// CUE sheets are library descriptors rather than playable files. Source
    /// scanners enumerate them separately and expand their INDEX 01 entries
    /// into virtual Song rows that all point at the referenced audio image.
    public static let supportedCueSheetExtensions: Set<String> = ["cue"]
}

/// Stable identifiers for playlists mirrored from a server-side music library
/// (Subsonic/Navidrome/Airsonic/gonic, Jellyfin/Emby/Plex).
///
/// The source ID is part of the prefix so two servers of the same kind — or the
/// same server re-added under a new source UUID — never collide, and so pruning
/// one source's stale mirrors cannot touch another's.
public enum ServerPlaylistIdentity {
    public static let playlistIDPrefix = "primuse.system.serverPlaylist."

    /// `primuse.system.serverPlaylist.<sourceID>.<serverPlaylistID>`
    public static func playlistID(sourceID: String, serverPlaylistID: String) -> String {
        "\(playlistIDPrefix)\(sourceID).\(serverPlaylistID)"
    }

    /// Prefix covering every mirror belonging to one source. Passed to
    /// `MusicLibrary.prunePlaylists(withIDPrefix:keepingIDs:)`.
    public static func playlistIDPrefix(sourceID: String) -> String {
        "\(playlistIDPrefix)\(sourceID)."
    }

    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        playlistID.hasPrefix(playlistIDPrefix)
    }

    /// Recovers the server-native item ID from a `Song.filePath` produced by a
    /// server-library connector: `/songs/<id>.<suffix>` (Subsonic) or
    /// `/items/<id>.<ext>` (Jellyfin/Emby/Plex).
    ///
    /// Playlist entries are matched through this rather than by recomputing the
    /// `Song.id` hash, because that hash includes the file extension and a
    /// playlist response can report a different (or missing) suffix than the
    /// catalogue scan did.
    public static func serverItemID(fromFilePath filePath: String) -> String? {
        let last = (filePath as NSString).lastPathComponent
        guard last.isEmpty == false else { return nil }
        let stripped = (last as NSString).deletingPathExtension
        return stripped.isEmpty ? nil : stripped
    }
}

/// Pure reconciliation rule shared by server-playlist sync and its tests.
/// A mirror survives pruning when its detail was synchronized successfully or
/// when the server listed it but its detail fetch failed in this snapshot.
public enum ServerPlaylistReconciliationPolicy {
    public static func mirrorIDsToKeep(
        sourceID: String,
        synchronizedServerPlaylistIDs: [String],
        failedServerPlaylistIDs: Set<String>
    ) -> Set<String> {
        Set(synchronizedServerPlaylistIDs)
            .union(failedServerPlaylistIDs)
            .reduce(into: Set<String>()) { result, serverPlaylistID in
                result.insert(ServerPlaylistIdentity.playlistID(
                    sourceID: sourceID,
                    serverPlaylistID: serverPlaylistID
                ))
            }
    }
}

/// Stable identifiers shared by the app targets and the Apple Music adapter.
///
/// `MusicLibrary` is also compiled into the tvOS target, while the concrete
/// MusicKit-backed service is not. Keeping these values in PrimuseKit prevents
/// the shared library model from depending on a platform-specific service.
public enum AppleMusicLibraryIdentity {
    public static let sourceID = "primuse.appleMusic.system"
    public static let systemPlaylistID = "primuse.system.appleMusicLibrary"
    public static let userPlaylistIDPrefix = "primuse.system.appleMusic.playlist."
    public static let notInPlaylistCollectionID = "primuse.system.appleMusic.notInPlaylist"

    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        playlistID == systemPlaylistID
            || playlistID.hasPrefix(userPlaylistIDPrefix)
    }
}

/// Any playlist Primuse regenerates locally from an external library rather than
/// storing as user data — Apple Music mirrors and server-library mirrors.
///
/// These share three behaviours: the next sync overwrites their contents, the UI
/// must not offer destructive edits (a deleted mirror reappears), and they are
/// excluded from CloudKit — a device that cannot resolve the same external
/// library would receive an unresolvable, and therefore empty, playlist and push
/// that emptiness back to the device that could resolve it.
public enum MirrorPlaylistIdentity {
    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        AppleMusicLibraryIdentity.isMirrorPlaylist(playlistID)
            || ServerPlaylistIdentity.isMirrorPlaylist(playlistID)
    }
}

/// Stable key for a user-hidden authoritative mirror. The upstream source and
/// upstream playlist identity are stored separately so a newly-created remote
/// playlist remains visible even when it reuses the same display name.
public struct MirrorPlaylistSuppressionKey: Codable, Hashable, Sendable {
    public let sourceID: String
    public let remotePlaylistID: String

    public init(sourceID: String, remotePlaylistID: String) {
        self.sourceID = sourceID
        self.remotePlaylistID = remotePlaylistID
    }
}

public struct MirrorPlaylistSuppression: Codable, Hashable, Sendable, Identifiable {
    public let key: MirrorPlaylistSuppressionKey
    public var playlistID: String
    public var displayName: String
    public var hiddenAt: Date

    public var id: String { "\(key.sourceID)\u{1F}\(key.remotePlaylistID)" }

    public init(
        key: MirrorPlaylistSuppressionKey,
        playlistID: String,
        displayName: String,
        hiddenAt: Date = Date()
    ) {
        self.key = key
        self.playlistID = playlistID
        self.displayName = displayName
        self.hiddenAt = hiddenAt
    }
}

public enum MirrorPlaylistSuppressionPolicy {
    public static let appleMusicLibraryRemoteID = "library"

    public static func key(forPlaylistID playlistID: String) -> MirrorPlaylistSuppressionKey? {
        if playlistID == AppleMusicLibraryIdentity.systemPlaylistID {
            return MirrorPlaylistSuppressionKey(
                sourceID: AppleMusicLibraryIdentity.sourceID,
                remotePlaylistID: appleMusicLibraryRemoteID
            )
        }
        if playlistID.hasPrefix(AppleMusicLibraryIdentity.userPlaylistIDPrefix) {
            let remoteID = String(playlistID.dropFirst(AppleMusicLibraryIdentity.userPlaylistIDPrefix.count))
            guard !remoteID.isEmpty else { return nil }
            return MirrorPlaylistSuppressionKey(
                sourceID: AppleMusicLibraryIdentity.sourceID,
                remotePlaylistID: remoteID
            )
        }
        guard playlistID.hasPrefix(ServerPlaylistIdentity.playlistIDPrefix) else { return nil }
        let remainder = playlistID.dropFirst(ServerPlaylistIdentity.playlistIDPrefix.count)
        guard let separator = remainder.firstIndex(of: ".") else { return nil }
        let sourceID = String(remainder[..<separator])
        let remoteID = String(remainder[remainder.index(after: separator)...])
        guard !sourceID.isEmpty, !remoteID.isEmpty else { return nil }
        return MirrorPlaylistSuppressionKey(sourceID: sourceID, remotePlaylistID: remoteID)
    }

    public static func isSuppressed(
        playlistID: String,
        suppressions: Set<MirrorPlaylistSuppressionKey>
    ) -> Bool {
        guard let key = key(forPlaylistID: playlistID) else { return false }
        return suppressions.contains(key)
    }
}

/// Platform-neutral identity used to reconcile the two IDs MusicKit exposes
/// for the same Apple Music track: a user-library ID (`i.*`) and a catalog ID.
public struct AppleMusicTrackIdentity: Sendable, Equatable {
    public let itemID: String
    public let alternateIDs: Set<String>
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?

    public init(
        itemID: String,
        alternateIDs: Set<String> = [],
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.itemID = itemID
        self.alternateIDs = alternateIDs
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Resolves a MusicKit playback item back to the canonical user-library item.
/// ID overlap is authoritative; normalized metadata is a conservative fallback
/// for MusicKit responses whose `PlayParameters` omit the catalog identifier.
public enum AppleMusicTrackIdentityResolver {
    public static func canonicalID(
        for playback: AppleMusicTrackIdentity,
        in library: [AppleMusicTrackIdentity]
    ) -> String? {
        guard !library.isEmpty else { return nil }

        let playbackIDs = playback.alternateIDs.union([playback.itemID])
        let exact = library.filter {
            !$0.alternateIDs.union([$0.itemID]).isDisjoint(with: playbackIDs)
        }
        if exact.count == 1 { return exact[0].itemID }

        let normalizedTitle = normalize(playback.title)
        guard !normalizedTitle.isEmpty else { return nil }
        let titleMatches = library.filter { normalize($0.title) == normalizedTitle }
        guard !titleMatches.isEmpty else { return nil }

        let ranked = titleMatches.map { candidate in
            (candidate.itemID, metadataScore(playback: playback, candidate: candidate))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0 < $1.0
        }

        guard let best = ranked.first, best.1 >= 4 else { return nil }
        if ranked.count > 1, ranked[1].1 == best.1 { return nil }
        return best.0
    }

    private static func metadataScore(
        playback: AppleMusicTrackIdentity,
        candidate: AppleMusicTrackIdentity
    ) -> Int {
        var score = 0

        let playbackArtist = normalize(playback.artist)
        let candidateArtist = normalize(candidate.artist)
        if !playbackArtist.isEmpty, playbackArtist == candidateArtist { score += 5 }

        let playbackAlbum = normalize(playback.album)
        let candidateAlbum = normalize(candidate.album)
        if !playbackAlbum.isEmpty, playbackAlbum == candidateAlbum { score += 3 }

        if let lhs = playback.duration, lhs > 0,
           let rhs = candidate.duration, rhs > 0 {
            let delta = abs(lhs - rhs)
            if delta <= 0.75 {
                score += 4
            } else if delta <= 2.5 {
                score += 3
            }
        }

        return score
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Whether an Apple Music response is a complete cloud snapshot or merely the
/// local-device fallback. Only a complete snapshot may prune songs/playlists.
public enum AppleMusicLibrarySyncMode: Sendable, Equatable {
    case authoritative
    case partialFallback

    public var shouldPruneMissingSongs: Bool { self == .authoritative }
    public var shouldReplaceMirrorPlaylist: Bool { self == .authoritative }
}

/// Preferences that affect the platform-neutral music-library projection.
///
/// The Apple Music settings UI and the shared library model must read the same
/// key. This lives outside the MusicKit implementation so macOS/iOS and tvOS
/// can all compile the shared model without target-membership assumptions.
public enum AppleMusicLibraryPreferences {
    public static let syncUserLibraryKey = "primuse.appleMusic.syncUserLibrary"

    public static var syncUserLibraryEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: syncUserLibraryKey) != nil else { return true }
        return defaults.bool(forKey: syncUserLibraryKey)
    }
}

/// Pure policy for deciding whether a MusicKit queue snapshot may replace
/// Primuse's canonical playback queue.
public enum AppleMusicQueueMirrorPolicy {
    public static func isActiveSession(
        sessionGeneration: UInt64,
        activeGeneration: UInt64,
        isCancelled: Bool
    ) -> Bool {
        sessionGeneration == activeGeneration && !isCancelled
    }

    public static func shouldApplySnapshot(
        sessionGeneration: UInt64,
        activeGeneration: UInt64,
        isCancelled: Bool,
        primuseOwnsCanonicalQueue: Bool,
        snapshotCount: Int
    ) -> Bool {
        isActiveSession(
            sessionGeneration: sessionGeneration,
            activeGeneration: activeGeneration,
            isCancelled: isCancelled
        )
            && !primuseOwnsCanonicalQueue
            && snapshotCount > 0
    }
}

/// Decides whether MusicKit or Primuse owns the ordering for an Apple Music
/// item. Any item selected from Primuse's visible queue must remain
/// Primuse-managed, including queues made entirely of Apple Music songs.
public enum AppleMusicQueueOwnershipPolicy {
    public static func shouldUsePrimuseQueue(
        selectedQueueEntryMatches: Bool
    ) -> Bool {
        selectedQueueEntryMatches
    }
}

public enum NetworkCredentialPolicy {
    public enum LookupResult: Equatable, Sendable {
        case found(String)
        case notFound
        case temporarilyUnavailable(Int32)
        case failed(Int32)

        public var password: String? {
            guard case .found(let password) = self else { return nil }
            return password
        }
    }

    public enum ConnectorResolution: Equatable, Sendable {
        case ready(String)
        case temporarilyUnavailable(Int32)
        case failed(Int32)
    }

    public static func username(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func password(_ value: String) -> String {
        value
    }

    public static func resolveForConnector(_ lookup: LookupResult) -> ConnectorResolution {
        switch lookup {
        case .found(let password): return .ready(password)
        case .notFound: return .ready("")
        case .temporarilyUnavailable(let status): return .temporarilyUnavailable(status)
        case .failed(let status): return .failed(status)
        }
    }

    /// A replacement credential is eligible for persistence only after the
    /// remote service has accepted it and an authenticated browse request has
    /// succeeded. Until then callers must keep using the last durable value.
    public static func validatedReplacement(
        candidate: String?,
        loginSucceeded: Bool,
        browserReady: Bool
    ) -> String? {
        guard loginSucceeded, browserReady else { return nil }
        return candidate
    }
}

/// NIOSSH advertises only AES-GCM transport ciphers by default. Some NAS SSH
/// servers (including Dropbear builds) advertise CTR ciphers instead, so SFTP
/// must add the narrow compatibility cipher before key exchange begins.
public enum SFTPTransportCompatibilityPolicy {
    public enum Profile: Equatable, Sendable {
        case libraryDefaults
        case aes128CTR
    }

    public static let connectionProfile: Profile = .aes128CTR

    public static func hasCipherOverlap(
        client: Set<String>,
        server: Set<String>
    ) -> Bool {
        !client.isDisjoint(with: server)
    }
}

/// Resolves Keychain lookup results for Scrobble providers without treating a
/// read failure as a definitively missing token. Providers whose credentials
/// are temporarily unreadable remain eligible for the durable retry queue;
/// providers that are definitively unconfigured do not create new queue rows.
public enum ScrobbleCredentialAvailabilityPolicy {
    public enum ValueResolution: Equatable, Sendable {
        case ready(String)
        case notConfigured
        case unavailable
    }

    public enum ProviderResolution: Equatable, Sendable {
        case ready
        case notConfigured
        case unavailable
    }

    public static func resolveValue(
        _ lookup: NetworkCredentialPolicy.LookupResult,
        fallback: String = ""
    ) -> ValueResolution {
        switch lookup {
        case .found(let value):
            if !value.isEmpty { return .ready(value) }
            return fallback.isEmpty ? .notConfigured : .ready(fallback)
        case .notFound:
            return fallback.isEmpty ? .notConfigured : .ready(fallback)
        case .temporarilyUnavailable, .failed:
            return .unavailable
        }
    }

    public static func resolveProvider(
        _ values: [ValueResolution]
    ) -> ProviderResolution {
        guard !values.isEmpty else { return .notConfigured }
        if values.contains(.unavailable) { return .unavailable }
        if values.allSatisfy({
            if case .ready = $0 { return true }
            return false
        }) {
            return .ready
        }
        return .notConfigured
    }

    public static func shouldQueue(_ resolution: ProviderResolution) -> Bool {
        resolution == .ready || resolution == .unavailable
    }
}

/// Distinguishes Apple Music catalog playback from the two kinds of items that
/// can appear in the user's Music library. A library row is not automatically
/// subscription-independent: an Apple Music catalog item can remain in the
/// library after the subscription expires.
public enum AppleMusicPlaybackSource: Sendable, Equatable {
    case catalog
    case catalogBackedUserLibrary
    case unverifiedUserLibrary
    case subscriptionIndependentUserLibrary
}

/// Resolves the opaque identifiers MusicKit supplies for a `Song` into the
/// narrowest safe playback source. Library IDs use the `i.` namespace; an
/// additional catalog/global ID means the row still represents catalog
/// content and must retain the no-subscription crash guard.
public enum AppleMusicPlaybackSourceResolver {
    public static func resolve(
        itemID: String,
        explicitCatalogIDs: Set<String>,
        genericPlayParameterIDs: Set<String>,
        confirmedLibraryIDs: Set<String>,
        confirmedLocalFileIDs: Set<String> = []
    ) -> AppleMusicPlaybackSource {
        let observedLibraryIDs = genericPlayParameterIDs
            .union(confirmedLibraryIDs)
            .union([itemID])
        let hasConfirmedLocalFile = !observedLibraryIDs.isDisjoint(with: confirmedLocalFileIDs)

        // MusicKit on macOS can expose an imported Music.app row using its
        // signed decimal persistent ID rather than the `i.*` namespace. Such
        // an ID is library-only only when iTunesLibrary independently confirms
        // that the row points at a readable, non-DRM local file.
        guard itemID.hasPrefix("i.") || hasConfirmedLocalFile else { return .catalog }

        if explicitCatalogIDs.contains(where: { !$0.isEmpty }) {
            return .catalogBackedUserLibrary
        }

        let hasAlternateCatalogID = genericPlayParameterIDs.contains { candidate in
            !candidate.isEmpty && candidate != itemID && !candidate.hasPrefix("i.")
        }
        if hasAlternateCatalogID {
            return .catalogBackedUserLibrary
        }

        if hasConfirmedLocalFile {
            return .subscriptionIndependentUserLibrary
        }

        // `i.*` alone only identifies a row in the user's library. It does not
        // prove that the row is a locally imported, subscription-independent
        // item. Require the successfully decoded PlayParameters payload to
        // repeat that library identity; absent or malformed metadata must keep
        // the subscription preflight so MusicKit cannot hit its no-subscription
        // assertion path.
        guard confirmedLibraryIDs.contains(itemID) else {
            return .unverifiedUserLibrary
        }
        return .subscriptionIndependentUserLibrary
    }
}

/// Converts the bit pattern exposed by `ITMediaItem.persistentID` into every
/// decimal representation MusicKit has been observed to use. IDs above
/// `Int64.max` appear as negative decimal strings in `MusicLibraryRequest`.
public enum AppleMusicLocalFileIdentity {
    public static func playbackIdentifiers(forPersistentID persistentID: UInt64) -> Set<String> {
        [
            String(persistentID),
            String(Int64(bitPattern: persistentID)),
        ]
    }
}

/// Requires MusicKit and iTunesLibrary to agree on the same local library row.
/// A persistent-ID collision, a partial PlayParameters payload, or a non-song
/// item must not weaken the catalog subscription preflight.
public enum AppleMusicLocalFileProvenancePolicy {
    public static func confirmsLibrarySong(
        itemID: String,
        playParameterIDs: Set<String>,
        persistentIDs: Set<String>,
        declaresLibraryItem: Bool,
        mediaKinds: Set<String>,
        confirmedLocalFileIDs: Set<String>
    ) -> Bool {
        guard declaresLibraryItem,
              mediaKinds.contains(where: { $0.caseInsensitiveCompare("song") == .orderedSame }),
              playParameterIDs.contains(itemID),
              persistentIDs.contains(itemID),
              confirmedLocalFileIDs.contains(itemID) else {
            return false
        }
        return true
    }
}

/// Chooses the cold-cache lookup endpoint without treating an arbitrary
/// decimal catalog ID as a user-library item.
public enum AppleMusicItemLookupPolicy {
    public static func shouldUseUserLibrary(
        itemID: String,
        confirmedLocalFileIDs: Set<String>
    ) -> Bool {
        itemID.hasPrefix("i.") || confirmedLocalFileIDs.contains(itemID)
    }
}

/// Ends the optimistic loading state after MusicKit either starts producing
/// playback state or rejects the request during its subscription preflight.
public enum AppleMusicMirrorLoadingPolicy {
    public static func shouldFinishLoading(
        isPlaying: Bool,
        currentPlaybackTime: TimeInterval,
        playbackError: String?
    ) -> Bool {
        isPlaying || currentPlaybackTime > 0 || !(playbackError?.isEmpty ?? true)
    }
}

/// `MusicSubscription.canPlayCatalogContent` only describes catalog
/// privileges. Keep the guard for both catalog search results and catalog
/// items retained in the library, while allowing confirmed library-only items
/// such as locally imported files to reach ApplicationMusicPlayer.
public enum AppleMusicSubscriptionGatePolicy {
    public static func requiresCatalogCapability(
        for source: AppleMusicPlaybackSource
    ) -> Bool {
        source != .subscriptionIndependentUserLibrary
    }
}

public struct AppleMusicSystemQueuePlan: Equatable, Sendable {
    public let retainedIndices: [Int]
    public let startIndex: Int

    public init(retainedIndices: [Int], startIndex: Int) {
        self.retainedIndices = retainedIndices
        self.startIndex = startIndex
    }
}

/// Keeps a subscription-independent library start from smuggling catalog-backed
/// entries into an `ApplicationMusicPlayer` queue after the catalog preflight
/// has intentionally been bypassed for that starting item.
public enum AppleMusicSystemQueuePolicy {
    public static func plan(
        startingItemID: String,
        startingSource: AppleMusicPlaybackSource,
        queuedItemIDs: [String],
        queuedSources: [AppleMusicPlaybackSource]
    ) -> AppleMusicSystemQueuePlan? {
        guard queuedItemIDs.count == queuedSources.count,
              let originalStartIndex = queuedItemIDs.firstIndex(of: startingItemID) else {
            return nil
        }

        let retainedIndices: [Int]
        if startingSource == .subscriptionIndependentUserLibrary {
            retainedIndices = queuedSources.indices.filter {
                queuedSources[$0] == .subscriptionIndependentUserLibrary
            }
        } else {
            retainedIndices = Array(queuedSources.indices)
        }

        guard let startIndex = retainedIndices.firstIndex(of: originalStartIndex) else {
            return nil
        }
        return AppleMusicSystemQueuePlan(
            retainedIndices: retainedIndices,
            startIndex: startIndex
        )
    }
}

/// Pure policy for recognizing the end of a MusicKit track.
///
/// `ApplicationMusicPlayer` does not consistently settle on `.stopped`: some
/// OS versions pause and reset `playbackTime`, while others remain `.playing`
/// with a frozen clock. Callers therefore retain the furthest observed time and
/// use a short stall watchdog near the reported duration.
public enum AppleMusicPlaybackEndPolicy {
    public static func isNearEnd(
        duration: TimeInterval,
        playbackTime: TimeInterval,
        furthestObservedTime: TimeInterval
    ) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        let tolerance = min(5, max(1.5, duration * 0.02))
        let observedTime = max(playbackTime, furthestObservedTime)
        return observedTime >= max(0, duration - tolerance)
    }

    public static func shouldAdvance(
        hasObservedActivePlayback: Bool,
        isStopped: Bool,
        isPaused: Bool,
        wasPausedByUser: Bool,
        isPlaybackInterrupted: Bool,
        isNearEnd: Bool,
        stalledNearEndSampleCount: Int,
        stallSampleThreshold: Int
    ) -> Bool {
        guard hasObservedActivePlayback else { return false }
        if isPlaybackInterrupted { return false }
        if isStopped { return true }
        if isPaused && !wasPausedByUser && isNearEnd { return true }
        return isNearEnd
            && stallSampleThreshold > 0
            && stalledNearEndSampleCount >= stallSampleThreshold
    }
}

/// Versioned persistence for the Library/Home quick-access selection.
///
/// Version 1 stored a bare array and rendered Liked Songs outside that array,
/// which meant it could neither be hidden nor reordered. Version 2 stores the
/// complete ordered selection, including Liked Songs. Decoding a legacy array
/// prepends the supplied default pin once, preserving the old visible result.
public enum QuickAccessPinKind: String, Codable, Sendable {
    case album, artist, playlist
}

public struct QuickAccessPinReference: Codable, Hashable, Identifiable, Sendable {
    public let kind: QuickAccessPinKind
    public let itemID: String

    public init(kind: QuickAccessPinKind, itemID: String) {
        self.kind = kind
        self.itemID = itemID
    }

    public var id: String { "\(kind.rawValue):\(itemID)" }
}

public enum QuickAccessPinStorageCodec {
    private struct Envelope: Codable {
        let version: Int
        let pins: [QuickAccessPinReference]
    }

    public static func decode(
        _ rawValue: String,
        defaultPins: [QuickAccessPinReference],
        maximumCount: Int
    ) -> [QuickAccessPinReference] {
        guard maximumCount > 0 else { return [] }
        guard !rawValue.isEmpty, let data = rawValue.data(using: .utf8) else {
            return normalized(defaultPins, maximumCount: maximumCount)
        }

        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version >= 2 {
            return normalized(envelope.pins, maximumCount: maximumCount)
        }

        if let legacyPins = try? JSONDecoder().decode([QuickAccessPinReference].self, from: data) {
            return normalized(defaultPins + legacyPins, maximumCount: maximumCount)
        }

        return normalized(defaultPins, maximumCount: maximumCount)
    }

    public static func encode(
        _ pins: [QuickAccessPinReference],
        maximumCount: Int
    ) -> String {
        let envelope = Envelope(
            version: 2,
            pins: normalized(pins, maximumCount: maximumCount)
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalized(
        _ pins: [QuickAccessPinReference],
        maximumCount: Int
    ) -> [QuickAccessPinReference] {
        var seen = Set<QuickAccessPinReference>()
        var result: [QuickAccessPinReference] = []
        result.reserveCapacity(min(pins.count, maximumCount))
        for pin in pins where seen.insert(pin).inserted {
            result.append(pin)
            if result.count == maximumCount { break }
        }
        return result
    }
}

/// Picks songs that may extend an exhausted shuffle round. Existing queue IDs
/// and duplicates in the library snapshot are excluded so an expansion never
/// immediately replays the just-finished track or inflates the queue.
public enum ShuffleContinuationPolicy {
    public static func candidateIDs(
        queueIDs: [String],
        libraryIDs: [String],
        currentID: String?
    ) -> [String] {
        var excluded = Set(queueIDs)
        if let currentID { excluded.insert(currentID) }
        var emitted = Set<String>()
        return libraryIDs.filter { id in
            !id.isEmpty && !excluded.contains(id) && emitted.insert(id).inserted
        }
    }
}

/// Decides whether a manual "next" command is allowed to start another
/// decode. A one-song, repeat-off queue has no successor; treating modulo 1
/// as an advance only downloads and restarts the same remote file.
public enum ManualQueueAdvancePolicy {
    public static func shouldAdvance(
        queueCount: Int,
        repeatMode: RepeatMode,
        shuffleEnabled: Bool,
        hasSuccessor: Bool
    ) -> Bool {
        guard queueCount > 0 else { return false }
        guard queueCount == 1, repeatMode == .off else { return true }
        return shuffleEnabled && hasSuccessor
    }
}

public enum MiniPlayerSwipeAction: Equatable, Sendable {
    case previous
    case next
}

public struct MiniPlayerSwipeSample: Equatable, Sendable {
    public let translationX: Double
    public let translationY: Double
    public let velocityX: Double
    public let velocityY: Double
    public let startX: Double
    public let containerWidth: Double
    public let isRightToLeft: Bool

    public init(
        translationX: Double,
        translationY: Double,
        velocityX: Double,
        velocityY: Double,
        startX: Double,
        containerWidth: Double,
        isRightToLeft: Bool
    ) {
        self.translationX = translationX
        self.translationY = translationY
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.startX = startX
        self.containerWidth = containerWidth
        self.isRightToLeft = isRightToLeft
    }
}

public enum MiniPlayerSwipePolicy {
    public static let minimumGestureDistance = 12.0
    public static let distanceThreshold = 56.0
    public static let velocityThreshold = 650.0
    public static let minimumFlickDistance = 20.0
    public static let horizontalDominanceRatio = 1.25
    public static let leadingEdgeExclusion = 24.0
    public static let maximumFeedbackOffset = 18.0

    public static func action(for sample: MiniPlayerSwipeSample) -> MiniPlayerSwipeAction? {
        guard let hint = directionHint(for: sample) else { return nil }

        let horizontalDistance = abs(sample.translationX)
        let distanceQualified = horizontalDistance >= distanceThreshold
        let velocityQualified = horizontalDistance >= minimumFlickDistance
            && abs(sample.velocityX) >= velocityThreshold
            && abs(sample.velocityX) >= abs(sample.velocityY) * horizontalDominanceRatio
            && sample.translationX.sign == sample.velocityX.sign

        return distanceQualified || velocityQualified ? hint : nil
    }

    public static func directionHint(for sample: MiniPlayerSwipeSample) -> MiniPlayerSwipeAction? {
        guard !startsInSystemLeadingEdge(sample),
              abs(sample.translationX) >= minimumGestureDistance,
              abs(sample.translationX) >= abs(sample.translationY) * horizontalDominanceRatio else {
            return nil
        }
        return sample.translationX < 0 ? .next : .previous
    }

    public static func feedbackOffset(
        for sample: MiniPlayerSwipeSample,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion, directionHint(for: sample) != nil else { return 0 }
        return min(
            maximumFeedbackOffset,
            max(-maximumFeedbackOffset, sample.translationX * 0.22)
        )
    }

    private static func startsInSystemLeadingEdge(_ sample: MiniPlayerSwipeSample) -> Bool {
        guard sample.containerWidth > 0 else { return false }
        if sample.isRightToLeft {
            return sample.startX >= sample.containerWidth - leadingEdgeExclusion
        }
        return sample.startX <= leadingEdgeExclusion
    }
}

/// A source-wide authentication or connection failure makes every immediately
/// following entry from that source unavailable. Those entries can be skipped
/// without attempting more requests, while the first different provider stays
/// eligible so a mixed-source queue can continue playing.
public enum SourceFailureAdvancePolicy {
    public static func shouldSkipCandidate(
        failedSourceID: String,
        candidateSourceID: String
    ) -> Bool {
        failedSourceID == candidateSourceID
    }
}

/// Shared predicate for the background metadata pipeline. A scanner can mark
/// only the title inspection as complete while still leaving duration or MP3
/// artwork work eligible for backfill.
public enum MetadataBackfillEligibilityPolicy {
    public static func needsBackfill(
        duration: TimeInterval,
        format: AudioFormat,
        hasCoverArt: Bool,
        artworkGivenUp: Bool,
        titleChecked: Bool,
        durationInspectionComplete: Bool = false
    ) -> Bool {
        (duration <= 0 && !durationInspectionComplete)
            || (format == .mp3 && !hasCoverArt && !artworkGivenUp)
            || !titleChecked
    }
}

/// A row's metadata state is independent from whether the media can be handed
/// to the player. In particular, STRM and complete-file decoder formats can be
/// playable while their duration remains unknown.
public enum SongDetailsState: Equatable, Sendable {
    case ready
    case reading
    case waitingForSource
    case playableIncomplete
    case confirmedFailure

    public static func resolve(
        duration: TimeInterval,
        isStandaloneMusicVideo: Bool,
        isPlayable: Bool,
        isReading: Bool,
        isWaitingForSource: Bool,
        isIncomplete: Bool,
        hasConfirmedFailure: Bool
    ) -> Self {
        if duration > 0 || isStandaloneMusicVideo { return .ready }
        if isWaitingForSource { return .waitingForSource }
        if isReading { return .reading }
        if isIncomplete || (isPlayable && !hasConfirmedFailure) {
            return .playableIncomplete
        }
        return .confirmedFailure
    }
}

/// Cancellation stops the current worker generation. It must not consume a
/// transient retry or park a song as though the source had failed.
public enum MetadataBackfillRetryPolicy {
    public static func shouldCountTransientFailure(
        isCancellation: Bool,
        isTransient: Bool
    ) -> Bool {
        isTransient && !isCancellation
    }
}

/// Accepts a server-catalog title as the completed title inspection only when
/// it contains a real value. Placeholder titles must retain the bounded file
/// header fallback so incomplete server metadata can still be repaired.
public enum ServerCatalogMetadataInspectionPolicy {
    public static func hasUsableTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        guard !MediaMetadataTextRepair.isSuspicious(title) else { return false }
        guard !TextEncodingRepair.requiresRawByteVerification(title) else { return false }
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return ![
            "unknown",
            "[unknown]",
            "unknown title",
            "[unknown title]",
            "unknown track",
            "[unknown track]",
            "untitled",
            "[untitled]",
            "未知",
            "[未知]",
            "未知标题",
            "[未知标题]",
            "未知標題",
            "[未知標題]",
            "未知歌曲",
            "[未知歌曲]",
            "无标题",
            "無標題"
        ].contains(normalized)
    }
}

/// User-visible execution state for metadata backfill. Pending work is kept
/// separate from active work so a deferred queue never presents itself as a
/// running spinner.
public enum MetadataBackfillActivityState: Equatable, Sendable {
    case idle
    case running
    case waitingForWiFi
    case pending

    public static func resolve(
        hasPendingWork: Bool,
        isRunning: Bool,
        isWaitingForWiFi: Bool
    ) -> Self {
        if isRunning { return .running }
        guard hasPendingWork else { return .idle }
        return isWaitingForWiFi ? .waitingForWiFi : .pending
    }
}

/// Stops a background metadata session after a complete round produces no
/// observable progress. The songs remain eligible on the next launch; parking
/// only suppresses an endless spinner and repeated network work in this run.
public enum MetadataBackfillStallPolicy {
    public static func shouldParkRepeatedSnapshot(
        previousIDs: Set<String>,
        currentIDs: Set<String>,
        hasTransientAttemptsBelowLimit: Bool = false
    ) -> Bool {
        !hasTransientAttemptsBelowLimit
            && !previousIDs.isEmpty
            && previousIDs == currentIDs
    }
}

public enum BaiduAPIErrorDisposition: Equatable, Sendable {
    case success
    case refreshAuthentication
    case retryAfterBackoff
    case missingPath
    case fail
}

/// Baidu returns application errors in an HTTP-200 JSON body. Keep the
/// provider-specific values out of generic HTTP classification: notably,
/// `-9` is a missing path, while only `31034` is the documented rate limit.
public enum BaiduAPIErrorPolicy {
    public static func disposition(errno: Int) -> BaiduAPIErrorDisposition {
        switch errno {
        case 0:
            return .success
        case -6, 111:
            return .refreshAuthentication
        case 31034:
            return .retryAfterBackoff
        case -9:
            return .missingPath
        default:
            return .fail
        }
    }
}

public enum ScanDirectoryFailureDisposition: Equatable, Sendable {
    case retainForResume
    case discardMissingChild
    case failMissingRoot
}

/// A selected root disappearing requires user action. A child remembered by
/// an older checkpoint can simply be dropped from that queue, while unknown
/// or transient failures remain resumable.
public enum ScanDirectoryFailurePolicy {
    public static func disposition(
        isMissingPath: Bool,
        isSelectedRoot: Bool
    ) -> ScanDirectoryFailureDisposition {
        guard isMissingPath else { return .retainForResume }
        return isSelectedRoot ? .failMissingRoot : .discardMissingChild
    }
}

public enum CloudHTTPRetryPolicy {
    public static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
    }

    public static func shouldRetry(urlErrorCode: Int) -> Bool {
        switch URLError.Code(rawValue: urlErrorCode) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

public enum GoogleDriveHTTPDisposition: Equatable, Sendable {
    case retryRateLimit
    case permissionDenied
    case other
}

/// Google uses HTTP 403 for both permanent permission failures and documented
/// per-user/project quota throttling. Only the two Drive rate-limit reasons
/// are retryable; an ordinary 403 must still stop at the source boundary.
public enum GoogleDriveHTTPErrorPolicy {
    public static func disposition(
        statusCode: Int,
        reasons: Set<String>
    ) -> GoogleDriveHTTPDisposition {
        guard statusCode == 403 else { return .other }
        if !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"]) {
            return .retryRateLimit
        }
        return .permissionDenied
    }
}

/// Pagination must make globally monotonic progress within a request. This
/// rejects empty tokens and cycles such as A -> B -> A, not just a token that
/// repeats on two adjacent pages.
public enum CloudPaginationTokenPolicy {
    public static func canAdvance(
        to token: String,
        seenTokens: Set<String>
    ) -> Bool {
        !token.isEmpty && !seenTokens.contains(token)
    }
}

/// Protects the identity supplied by a CUE sheet when metadata is scraped from
/// the shared physical audio file. A forced scrape may replace ordinary-track
/// text, but it must not collapse every virtual segment to one file-level name.
public enum ScrapeCueIdentityPolicy {
    public static func resolvedTitle(
        original: String,
        scraped: String,
        isCueTrack: Bool
    ) -> String {
        guard isCueTrack, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scraped
        }
        return original
    }

    public static func resolvedOptionalText(
        original: String?,
        scraped: String?,
        isCueTrack: Bool
    ) -> String? {
        guard isCueTrack,
              let original,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scraped
        }
        return original
    }
}

/// Prevents metadata scraping from materializing an entire remote audio file
/// merely to establish a search identity. Range-capable sources already feed
/// embedded tags through metadata backfill; formats that require a complete
/// local file should only download that file when the user actually plays or
/// explicitly caches it.
public enum ScrapeAudioMaterializationPolicy {
    public static func shouldResolvePlaybackURL(
        sourceSupportsRangeStreaming: Bool,
        formatRequiresCompleteLocalFile: Bool
    ) -> Bool {
        !(sourceSupportsRangeStreaming && formatRequiresCompleteLocalFile)
    }
}

/// Decides how a trusted, confidence-checked online scrape candidate is
/// applied to the library seed. Background enrichment keeps its conservative
/// fill-only contract, while an explicit rescrape may replace known catalog
/// fields. Empty provider values never erase local metadata in either mode.
public enum ScrapeMetadataApplicationPolicy {
    public static func shouldRequestMetadata(
        fieldsAreMissing: Bool,
        forceRefresh: Bool
    ) -> Bool {
        fieldsAreMissing || forceRefresh
    }

    public static func resolvedText(
        original: String?,
        scraped: String?,
        overwrite: Bool
    ) -> String? {
        let candidate = scraped?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return original }

        let existing = original?.trimmingCharacters(in: .whitespacesAndNewlines)
        if overwrite || existing?.isEmpty != false {
            return candidate
        }
        return original
    }

    public static func resolvedValue<Value>(
        original: Value?,
        scraped: Value?,
        overwrite: Bool
    ) -> Value? {
        if overwrite {
            return scraped ?? original
        }
        return original ?? scraped
    }
}

/// A deterministic rank for scrape candidates. Title compatibility remains
/// the identity gate. Within that gate, every usable duration ranks ahead of a
/// missing duration, then exact duration distance, title, and artist decide the
/// order. Metadata completeness only breaks remaining identity ties.
public struct ScrapeCandidateRank: Sendable, Equatable {
    public enum DurationTier: Int, Sendable, Equatable {
        case close = 0
        case plausible = 1
        case mismatch = 2
        case unknown = 3
        case unavailable = 4
    }

    public enum ArtistTier: Int, Sendable, Equatable {
        case exact = 0
        case partial = 1
        case unavailable = 2
        case conflict = 3
    }

    public let confidence: Double
    public let titleMatchLevel: Int
    public let artistMatchLevel: Int
    public let artistTier: ArtistTier
    public let durationTier: DurationTier
    public let durationDeltaMs: Int?
    public let metadataCompleteness: Int
}

public enum ScrapeCandidateRankingPolicy {
    public static func rank(
        requestedTitle: String,
        requestedArtist: String?,
        targetDurationMs: Int?,
        candidateTitle: String,
        candidateArtist: String?,
        candidateDurationMs: Int?,
        candidateAlbum: String? = nil,
        candidateYear: Int? = nil,
        candidateHasArtwork: Bool = false,
        candidateTrackNumber: Int? = nil,
        candidateGenreCount: Int = 0
    ) -> ScrapeCandidateRank {
        let titleMatchLevel = textMatchLevel(
            requested: requestedTitle,
            candidate: candidateTitle
        )
        let artistMatchLevel = textMatchLevel(
            requested: requestedArtist,
            candidate: candidateArtist
        )
        let normalizedRequestedArtist = normalized(requestedArtist)
        let normalizedCandidateArtist = normalized(candidateArtist)
        let artistTier: ScrapeCandidateRank.ArtistTier
        if normalizedRequestedArtist.isEmpty || normalizedCandidateArtist.isEmpty {
            artistTier = .unavailable
        } else if artistMatchLevel == 2 {
            artistTier = .exact
        } else if artistMatchLevel == 1 {
            artistTier = .partial
        } else {
            artistTier = .conflict
        }

        var score = 0.0
        var maximumScore = 30.0
        score += titleMatchLevel == 2 ? 30 : (titleMatchLevel == 1 ? 15 : 0)

        if !normalizedRequestedArtist.isEmpty {
            maximumScore += 20
            score += artistMatchLevel == 2 ? 20 : (artistMatchLevel == 1 ? 10 : 0)
        }

        let validTargetMs = targetDurationMs.flatMap { $0 > 0 ? $0 : nil }
        let validCandidateMs = candidateDurationMs.flatMap { $0 > 0 ? $0 : nil }
        let durationTier: ScrapeCandidateRank.DurationTier
        let durationDeltaMs: Int?
        if let targetMs = validTargetMs {
            maximumScore += 50
            if let candidateMs = validCandidateMs {
                let delta = abs(candidateMs - targetMs)
                durationDeltaMs = delta
                let plausibleToleranceMs = max(10_000, min(30_000, targetMs / 10))
                if delta < 2_000 {
                    score += 50
                } else if delta < 5_000 {
                    score += 30
                } else if delta < 10_000 {
                    score += 10
                } else if delta <= plausibleToleranceMs {
                    score += 5
                } else {
                    score -= 20
                }
                if delta < 10_000 {
                    durationTier = .close
                } else if delta <= plausibleToleranceMs {
                    durationTier = .plausible
                } else {
                    durationTier = .mismatch
                }
            } else {
                durationDeltaMs = nil
                durationTier = .unknown
            }
        } else {
            durationDeltaMs = nil
            durationTier = .unavailable
        }

        let confidence = maximumScore > 0
            ? max(0, min(1, score / maximumScore))
            : 0
        let metadataCompleteness = informationCompleteness(
            durationMs: validCandidateMs,
            album: candidateAlbum,
            year: candidateYear,
            hasArtwork: candidateHasArtwork,
            trackNumber: candidateTrackNumber,
            genreCount: candidateGenreCount
        )
        return ScrapeCandidateRank(
            confidence: confidence,
            titleMatchLevel: titleMatchLevel,
            artistMatchLevel: artistMatchLevel,
            artistTier: artistTier,
            durationTier: durationTier,
            durationDeltaMs: durationDeltaMs,
            metadataCompleteness: metadataCompleteness
        )
    }

    public static func isPreferred(
        _ lhs: ScrapeCandidateRank,
        over rhs: ScrapeCandidateRank
    ) -> Bool {
        let lhsTitleCompatible = lhs.titleMatchLevel > 0
        let rhsTitleCompatible = rhs.titleMatchLevel > 0
        if lhsTitleCompatible != rhsTitleCompatible {
            return lhsTitleCompatible
        }

        if lhs.durationTier != rhs.durationTier {
            return lhs.durationTier.rawValue < rhs.durationTier.rawValue
        }
        if let lhsDelta = lhs.durationDeltaMs,
           let rhsDelta = rhs.durationDeltaMs,
           lhsDelta != rhsDelta {
            return lhsDelta < rhsDelta
        }
        if lhs.titleMatchLevel != rhs.titleMatchLevel {
            return lhs.titleMatchLevel > rhs.titleMatchLevel
        }
        if lhs.artistTier != rhs.artistTier {
            return lhs.artistTier.rawValue < rhs.artistTier.rawValue
        }
        if lhs.metadataCompleteness != rhs.metadataCompleteness {
            return lhs.metadataCompleteness > rhs.metadataCompleteness
        }

        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return false
    }

    private static func informationCompleteness(
        durationMs: Int?,
        album: String?,
        year: Int?,
        hasArtwork: Bool,
        trackNumber: Int?,
        genreCount: Int
    ) -> Int {
        var score = 0
        if durationMs != nil { score += 2 }
        if !normalized(album).isEmpty { score += 2 }
        if hasArtwork { score += 2 }
        if let year, year > 0 { score += 1 }
        if let trackNumber, trackNumber > 0 { score += 1 }
        if genreCount > 0 { score += 1 }
        return score
    }

    private static func textMatchLevel(
        requested: String?,
        candidate: String?
    ) -> Int {
        let requestedText = normalized(requested)
        let candidateText = normalized(candidate)
        guard !requestedText.isEmpty, !candidateText.isEmpty else { return 0 }
        if requestedText == candidateText { return 2 }
        if requestedText.contains(candidateText) || candidateText.contains(requestedText) {
            return 1
        }
        return 0
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

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

/// Detects a JPEG sampling layout that some FFmpeg encoders emit and Apple
/// ImageIO cannot decode reliably (`decodeImageImp failed - NULL _blockArray`).
/// The check parses only JPEG marker headers, so callers can reject or replace
/// the data without first triggering ImageIO's decoder.
public enum ArtworkImageCompatibility {
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
                return samples.allSatisfy { $0 == samples[0] } && samples[0] != 0x11
            }
            marker += length
        }
        return false
    }
}

/// Decides whether a visible artwork placeholder should retry after another
/// surface persists artwork for the same song. Successful images stay put;
/// explicit artwork replacement uses the separate invalidation notification.
public enum ArtworkCacheReloadPolicy {
    public static func shouldReload(
        cachedSongID: String?,
        displayedSongID: String?,
        hasResolvedImage: Bool
    ) -> Bool {
        guard !hasResolvedImage,
              let cachedSongID,
              !cachedSongID.isEmpty,
              let displayedSongID,
              !displayedSongID.isEmpty else {
            return false
        }
        return cachedSongID == displayedSongID
    }
}

public enum ImmersiveControlsAction: Sendable {
    case present
    case contentTap
    case lock
    case unlock
    case autoHide
    case dismiss
}

/// Interaction state shared by distraction-free lyrics and media surfaces.
/// Locking hides the chrome and intercepts content gestures; one content tap
/// reveals only the unlock affordance so accidental playback changes stay
/// impossible until the user explicitly unlocks the surface.
public struct ImmersiveControlsState: Equatable, Sendable {
    public let isVisible: Bool
    public let isLocked: Bool

    public static let inactive = Self(isVisible: false, isLocked: false)
    public static let presented = Self(isVisible: true, isLocked: false)

    public var showsPrimaryControls: Bool {
        isVisible && !isLocked
    }

    public var showsUnlockControl: Bool {
        isVisible && isLocked
    }

    public func applying(_ action: ImmersiveControlsAction) -> Self {
        switch action {
        case .present:
            return .presented
        case .contentTap:
            return isLocked
                ? Self(isVisible: true, isLocked: true)
                : Self(isVisible: !isVisible, isLocked: false)
        case .lock:
            return Self(isVisible: false, isLocked: true)
        case .unlock:
            return .presented
        case .autoHide:
            return Self(isVisible: false, isLocked: isLocked)
        case .dismiss:
            return .inactive
        }
    }
}

public enum NowPlayingLandscapeMode: Equatable, Sendable {
    case none
    case standardLyrics
    case immersiveLyrics
    case musicVideo
}

/// Keeps landscape presentation priority deterministic. Video always owns the
/// screen while active; lyrics use their immersive composition only after the
/// explicit full-screen action, never merely because normal lyrics are visible.
public enum NowPlayingLandscapePolicy {
    public static func mode(
        viewportWidth: Double,
        viewportHeight: Double,
        isMusicVideoActive: Bool,
        areLyricsVisible: Bool,
        areLyricsImmersive: Bool
    ) -> NowPlayingLandscapeMode {
        guard viewportWidth > viewportHeight else { return .none }
        if isMusicVideoActive { return .musicVideo }
        guard areLyricsVisible else { return .none }
        return areLyricsImmersive ? .immersiveLyrics : .standardLyrics
    }
}

/// Separates taps on rendered lyric rows from taps on unused lyric-surface
/// space. SwiftUI delivers the child and parent gestures in the same event
/// cycle, so a short window prevents a row seek from also switching surfaces.
public enum LyricsBackgroundTapPolicy {
    public static let rowSuppressionInterval: TimeInterval = 0.08

    public static func shouldHandle(
        hasLyrics: Bool,
        isPinching: Bool,
        rowTapTimeDistance: TimeInterval
    ) -> Bool {
        hasLyrics
            && !isPinching
            && abs(rowTapTimeDistance) > rowSuppressionInterval
    }
}

/// Decides whether Now Playing artwork should fall back to reading the cover
/// through its source connector. Absolute URLs have already used their own
/// network path; source-relative paths and opaque cloud identifiers still need
/// the connector so authenticated providers can return the sidecar bytes.
public enum NowPlayingArtworkFallbackPolicy {
    public static func shouldFetchFromConnector(
        reference: String?,
        directImageLoaded: Bool
    ) -> Bool {
        guard !directImageLoaded,
              let reference,
              !reference.isEmpty else {
            return false
        }
        return !reference.contains("://")
    }
}

/// Prevents artwork published for one item from being attached to the next
/// item while its own image is still loading. Some Bluetooth accessories only
/// sample artwork when the rest of the track metadata changes, so carrying the
/// previous image into that snapshot makes the display lag by one track.
public enum NowPlayingArtworkPublicationPolicy {
    public static func shouldReuseArtwork(
        ownedBy artworkSongID: String?,
        for currentSongID: String?
    ) -> Bool {
        guard let artworkSongID,
              !artworkSongID.isEmpty,
              let currentSongID,
              !currentSongID.isEmpty else {
            return false
        }
        return artworkSongID == currentSongID
    }
}

/// Validates the non-query portion of an OAuth callback URL.
///
/// Providers that redirect straight back to the app must return the registered
/// custom URL exactly (scheme/host are case-insensitive; path is not). Providers
/// that use an HTTPS relay can only be checked against the custom scheme because
/// their registered HTTPS URL differs from the deep link emitted by the relay.
public enum OAuthCallbackURLMatcher {
    public static func matches(
        _ callbackURL: URL,
        registeredRedirectURI: String,
        callbackScheme: String
    ) -> Bool {
        guard
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let actualScheme = callback.scheme?.lowercased(),
            actualScheme == callbackScheme.lowercased(),
            let registered = URLComponents(string: registeredRedirectURI),
            let registeredScheme = registered.scheme?.lowercased(),
            callback.user == nil,
            callback.password == nil,
            registered.user == nil,
            registered.password == nil
        else {
            return false
        }

        // An HTTPS relay ultimately emits a different custom URL. Preserve the
        // existing scheme-only behavior for that flow.
        guard registeredScheme == callbackScheme.lowercased() else {
            return true
        }

        return registeredScheme == actualScheme
            && registered.host?.lowercased() == callback.host?.lowercased()
            && registered.port == callback.port
            && registered.percentEncodedPath == callback.percentEncodedPath
    }
}

/// Deduplicates concurrent async work while keeping its required persistence
/// step inside the shared task. Every participant therefore observes the same
/// success or failure, including failures that happen after the remote work
/// itself has completed.
public actor PersistedTaskDeduplicator<Value: Sendable> {
    private var inFlight: (id: UUID, task: Task<Value, Error>)?

    public init() {}

    public func run(
        operation: @Sendable @escaping () async throws -> Value,
        persist: @Sendable @escaping (Value) async throws -> Void
    ) async throws -> Value {
        if let inFlight {
            return try await inFlight.task.value
        }

        let id = UUID()
        let task = Task<Value, Error> {
            let value = try await operation()
            try await persist(value)
            return value
        }
        inFlight = (id, task)

        do {
            let value = try await task.value
            clearInFlight(id: id)
            return value
        } catch {
            clearInFlight(id: id)
            throw error
        }
    }

    /// Retries only the durable write for a value whose remote operation has
    /// already succeeded. It deliberately shares `inFlight` with `run` so
    /// concurrent callers neither repeat the remote operation nor race the
    /// persistence retry.
    public func retryPersistence(
        of value: Value,
        persist: @Sendable @escaping (Value) async throws -> Void
    ) async throws -> Value {
        try await run(
            operation: { value },
            persist: persist
        )
    }

    private func clearInFlight(id: UUID) {
        if inFlight?.id == id {
            inFlight = nil
        }
    }
}

/// A source tombstone is the retry target for irreversible credential cleanup.
/// It may only be removed after every credential store owned by that source
/// reports success. Unrelated stores must not block deletion: for example, a
/// network share has no OAuth token, while a cloud drive has no source password.
public enum SourcePermanentDeletionPolicy {
    public enum CredentialStore: Hashable, Sendable {
        case password
        case cloudCredentials
    }

    public static func requiredCredentialStores(
        for sourceType: MusicSourceType,
        authType: SourceAuthType
    ) -> Set<CredentialStore> {
        var stores: Set<CredentialStore> = []
        if sourceType.requiresCredentials, authType != .none {
            stores.insert(.password)
        }
        if sourceType.isCloudDrive {
            stores.insert(.cloudCredentials)
        }
        return stores
    }

    public static func canRemoveTombstone(
        requiredStores: Set<CredentialStore>,
        passwordDeleted: Bool,
        cloudCredentialsDeleted: Bool
    ) -> Bool {
        (!requiredStores.contains(.password) || passwordDeleted)
            && (!requiredStores.contains(.cloudCredentials) || cloudCredentialsDeleted)
    }
}

/// A queue may contain the same song more than once. Including its position
/// keeps every visible occurrence distinct while still invalidating a row when
/// a different song replaces the same queue slot.
public struct QueueRowIdentity: Hashable, Sendable {
    public let position: Int
    public let songID: String

    public init(position: Int, songID: String) {
        self.position = position
        self.songID = songID
    }

    public static func make(for songIDs: [String]) -> [QueueRowIdentity] {
        songIDs.enumerated().map { position, songID in
            QueueRowIdentity(position: position, songID: songID)
        }
    }

    public static func makeVisible(
        for songIDs: [String],
        where isVisible: (String) -> Bool
    ) -> [QueueRowIdentity] {
        songIDs.enumerated().compactMap { position, songID in
            guard isVisible(songID) else { return nil }
            return QueueRowIdentity(position: position, songID: songID)
        }
    }
}

/// Splits a queue's current shuffle round into played and upcoming occurrences.
/// `roundOffset` distinguishes the same queue slot when repeat-all previews the
/// next round, while `queueIndex` keeps duplicate songs in separate slots.
public struct QueuePresentationOccurrence: Hashable, Sendable {
    public let queueIndex: Int
    public let roundOffset: Int

    public init(queueIndex: Int, roundOffset: Int) {
        self.queueIndex = queueIndex
        self.roundOffset = roundOffset
    }
}

/// Stable identity carried by a queue-row drag. `queueEntryID` identifies the
/// exact queue slot (not merely its Song), while `roundOffset` disambiguates a
/// slot that repeat-all presents again in the next shuffle round.
public struct QueueReorderOccurrenceID: Hashable, Sendable {
    private static let payloadPrefix = "primuse.queue-entry"

    public let queueEntryID: UUID
    public let roundOffset: Int

    public init(queueEntryID: UUID, roundOffset: Int) {
        self.queueEntryID = queueEntryID
        self.roundOffset = roundOffset
    }

    public var dragPayload: String {
        "\(Self.payloadPrefix)|\(queueEntryID.uuidString)|\(roundOffset)"
    }

    public init?(dragPayload: String) {
        let fields = dragPayload.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == Substring(Self.payloadPrefix),
              let queueEntryID = UUID(uuidString: String(fields[1])),
              let roundOffset = Int(fields[2]),
              roundOffset >= 0 else { return nil }
        self.init(queueEntryID: queueEntryID, roundOffset: roundOffset)
    }
}

/// Resolves a drop against the latest Up Next snapshot. Dropping a row over a
/// row above it inserts before the target; dropping over a row below it inserts
/// after the target. This makes either drag direction reach the edge position
/// while keeping played/current entries outside the mutation boundary.
public enum QueueUpcomingReorderPolicy {
    public static func reorderedOccurrences(
        dragging dragged: QueueReorderOccurrenceID,
        over target: QueueReorderOccurrenceID,
        queueEntryIDs: [UUID],
        upcomingOccurrences: [QueueReorderOccurrenceID]
    ) -> [QueueReorderOccurrenceID]? {
        guard dragged != target,
              dragged.roundOffset >= 0,
              dragged.roundOffset == target.roundOffset,
              Set(queueEntryIDs).count == queueEntryIDs.count,
              Set(upcomingOccurrences).count == upcomingOccurrences.count else { return nil }

        let queueEntryIDSet = Set(queueEntryIDs)
        guard upcomingOccurrences.allSatisfy({ queueEntryIDSet.contains($0.queueEntryID) }),
              let sourceIndex = upcomingOccurrences.firstIndex(of: dragged),
              let targetIndex = upcomingOccurrences.firstIndex(of: target) else { return nil }

        var reordered = upcomingOccurrences
        let moved = reordered.remove(at: sourceIndex)
        // `targetIndex` is still the correct insertion offset after removing a
        // preceding source (insert after target), and means "before target"
        // when removing a later source.
        reordered.insert(moved, at: targetIndex)
        return reordered == upcomingOccurrences ? nil : reordered
    }
}

/// Selects a prepared repeat-all shuffle round without regenerating it once a
/// caller has cached the first result. Callers persist the returned round and
/// feed it back on subsequent reads so previews, prefetch and playback agree.
public enum ShuffleRoundPreparationPolicy {
    public static func preparedRound(
        pending: [Int]?,
        generate: () -> [Int]
    ) -> [Int] {
        if let pending { return pending }
        return generate()
    }
}

public enum QueuePresentationPolicy {
    public static func playedOccurrences(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int
    ) -> [QueuePresentationOccurrence] {
        guard queueCount > 0 else { return [] }
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let end = min(max(currentIndex, 0), queueCount)
            return occurrences(in: Array(0..<end), queueCount: queueCount, roundOffset: 0)
        }

        let currentPosition = min(max(shufflePosition, 0), shuffledIndices.count - 1)
        let played = Array(shuffledIndices.prefix(currentPosition))
            .filter { $0 != currentIndex }
        return occurrences(in: played, queueCount: queueCount, roundOffset: 0)
    }

    public static func upcomingOccurrences(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int,
        nextRoundIndices: [Int]?
    ) -> [QueuePresentationOccurrence] {
        guard queueCount > 0 else { return [] }
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let start = min(max(currentIndex + 1, 0), queueCount)
            return occurrences(in: Array(start..<queueCount), queueCount: queueCount, roundOffset: 0)
        }

        let currentPosition = min(max(shufflePosition, 0), shuffledIndices.count - 1)
        let consumedCurrentRound = Set(
            shuffledIndices.prefix(currentPosition + 1).filter { (0..<queueCount).contains($0) }
        )
        let remaining = shuffledIndices.dropFirst(currentPosition + 1).filter {
            $0 != currentIndex && !consumedCurrentRound.contains($0)
        }
        var result = occurrences(
            in: Array(remaining),
            queueCount: queueCount,
            roundOffset: 0
        )
        if let nextRoundIndices {
            result.append(contentsOf: occurrences(
                in: nextRoundIndices,
                queueCount: queueCount,
                roundOffset: 1
            ))
        }
        return result
    }

    private static func occurrences(
        in indices: [Int],
        queueCount: Int,
        roundOffset: Int
    ) -> [QueuePresentationOccurrence] {
        var seen = Set<Int>()
        return indices.compactMap { index in
            guard (0..<queueCount).contains(index), seen.insert(index).inserted else { return nil }
            return QueuePresentationOccurrence(queueIndex: index, roundOffset: roundOffset)
        }
    }
}

/// Resolves queue navigation against the current library without mutating the
/// canonical queue. This lets playback survive source removal or disablement.
public enum QueueTraversalPolicy {
    public static func nextAvailableIndex(
        queueCount: Int,
        after currentIndex: Int,
        wraps: Bool,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        guard queueCount > 0 else { return nil }

        let forwardStart = max(0, currentIndex + 1)
        if forwardStart < queueCount {
            for index in forwardStart..<queueCount where isAvailable(index) {
                return index
            }
        }

        guard wraps, currentIndex >= 0 else { return nil }
        let wrapEnd = min(currentIndex, queueCount - 1)
        for index in 0...wrapEnd where isAvailable(index) {
            return index
        }
        return nil
    }

    public static func previousAvailableIndex(
        before currentIndex: Int,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        guard currentIndex > 0 else { return nil }
        for index in stride(from: currentIndex - 1, through: 0, by: -1)
        where isAvailable(index) {
            return index
        }
        return nil
    }
}

/// Rejects asynchronous playback work after another selection supersedes it.
/// Cancellation alone is insufficient because a resolver may finish normally
/// after its owning task has been cancelled.
public enum PlaybackRequestGenerationPolicy {
    public static func shouldApplyResult<RequestID: Equatable>(
        requestID: RequestID,
        activeRequestID: RequestID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestID == activeRequestID
    }
}

/// Keeps playback-owner transitions consistent without depending on any Apple
/// framework types. A pending Apple Music request already owns the upcoming
/// audio session even before its song has reached the shared now-playing UI.
public enum AppleMusicPlaybackOwnershipPolicy {
    /// Every local playback entry point must await a renderer Stop that was
    /// detached for an Apple Music handoff. Looking only at the visible cast
    /// controller is insufficient because it is nil while Stop is in flight.
    public static func shouldAwaitCastingHandoff(
        isLocalPlayback: Bool,
        hasPendingHandoff: Bool
    ) -> Bool {
        isLocalPlayback && hasPendingHandoff
    }

    public static func canStartCasting(
        isAppleMusicMode: Bool,
        hasActivePlaybackRequest: Bool
    ) -> Bool {
        !isAppleMusicMode && !hasActivePlaybackRequest
    }

    /// Local decoder callbacks need a fresh generation at end-of-track. Apple
    /// Music natural-end callbacks are already request-scoped, and retaining
    /// their token keeps the state mirror alive for replay from the stopped UI.
    public static func shouldInvalidatePlayIDAtTrackEnd(
        isAppleMusicMode: Bool,
        hasActivePlaybackRequest: Bool
    ) -> Bool {
        !isAppleMusicMode && !hasActivePlaybackRequest
    }
}

/// Chooses whether a Play/Pause toggle can control the current MusicKit
/// generation or must rebuild playback restored from a previous app process.
public enum AppleMusicTogglePlaybackPolicy {
    public enum Action: Equatable, Sendable {
        case toggleActiveRequest
        case rebuildRestoredRequest
    }

    public static func action(hasStartedPlaybackRequest: Bool) -> Action {
        hasStartedPlaybackRequest ? .toggleActiveRequest : .rebuildRestoredRequest
    }
}

/// Decides whether playback needs the complete Apple Music library cache.
/// A Primuse-managed queue hands MusicKit only the current DRM item, so a
/// direct lookup can start immediately while the full library keeps syncing.
public enum AppleMusicPlaybackCachePolicy {
    public static func requiresCompleteLibrarySnapshot(
        hasQueueContext: Bool,
        appleMusicItemCount: Int
    ) -> Bool {
        !hasQueueContext || appleMusicItemCount != 1
    }
}

/// Revalidates every condition that makes a user-library playback request
/// meaningful after a shared sync suspension.
public enum AppleMusicLibraryPlaybackGatePolicy {
    public static func canContinue(
        requestIsPending: Bool,
        isCancelled: Bool,
        syncEnabled: Bool,
        sourceEnabled: Bool,
        isAuthorized: Bool
    ) -> Bool {
        requestIsPending
            && !isCancelled
            && syncEnabled
            && sourceEnabled
            && isAuthorized
    }
}

/// Prevents a delayed error-dismiss timer from clearing a newer playback
/// request's message, including the case where the text happens to match.
public enum PlaybackErrorDismissalPolicy {
    public static func shouldDismiss<RequestID: Equatable>(
        requestID: RequestID?,
        activeRequestID: RequestID?,
        scheduledMessage: String,
        currentMessage: String?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && requestID == activeRequestID
            && scheduledMessage == currentMessage
    }
}

/// An AVPlayer end notification is valid only for the item that is both still
/// active in the engine and still installed on the player. This rejects queued
/// notifications from an item detached by a newer selection or cancellation.
public enum PlaybackEndIdentityPolicy {
    public static func shouldAdvance<ItemID: Equatable>(
        endedItemID: ItemID,
        activeItemID: ItemID?,
        currentItemID: ItemID?
    ) -> Bool {
        endedItemID == activeItemID && endedItemID == currentItemID
    }
}

/// Limits tvOS decoded-playback cleanup to files created in the immediate
/// temporary directory with the app-owned prefix. The guard prevents an
/// unexpected URL from turning lifecycle cleanup into an arbitrary deletion.
public enum TVDecodedTemporaryFilePolicy {
    public static let fileNamePrefix = "tvsfb-"

    public static func makeURL(
        in temporaryDirectory: URL,
        fileExtension: String,
        identifier: UUID = UUID()
    ) -> URL {
        let sanitizedExtension = fileExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let resolvedExtension = sanitizedExtension.isEmpty ? "bin" : sanitizedExtension
        return temporaryDirectory.appendingPathComponent(
            "\(fileNamePrefix)\(identifier.uuidString).\(resolvedExtension)",
            isDirectory: false
        )
    }

    public static func isManagedFile(
        _ fileURL: URL,
        in temporaryDirectory: URL
    ) -> Bool {
        guard fileURL.isFileURL, temporaryDirectory.isFileURL else { return false }
        let standardizedFile = fileURL.standardizedFileURL
        let standardizedDirectory = temporaryDirectory.standardizedFileURL
        return standardizedFile.deletingLastPathComponent().path == standardizedDirectory.path
            && standardizedFile.lastPathComponent.hasPrefix(fileNamePrefix)
    }

    @discardableResult
    public static func removeIfManaged(
        _ fileURL: URL,
        in temporaryDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard isManagedFile(fileURL, in: temporaryDirectory),
              fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        return true
    }
}

/// Validates the byte-accounting boundaries shared by tvOS whole-file decoder
/// downloads. Short nonempty chunks may continue, but empty/oversized chunks
/// and any final byte-count mismatch must fail closed.
public enum ExactChunkedDownloadPolicy {
    public enum ChunkDecision: Equatable, Sendable {
        case append
        case rejectEmpty
        case rejectOversized
    }

    public static func contentLengthIsValid(_ contentLength: Int64) -> Bool {
        contentLength >= 0
    }

    public static func chunkDecision(
        requestedLength: Int64,
        receivedLength: Int
    ) -> ChunkDecision {
        guard receivedLength > 0 else { return .rejectEmpty }
        guard requestedLength > 0,
              Int64(receivedLength) <= requestedLength else {
            return .rejectOversized
        }
        return .append
    }

    public static func isComplete(
        expectedLength: Int64,
        writtenLength: Int64
    ) -> Bool {
        expectedLength >= 0 && writtenLength == expectedLength
    }
}

/// A library can contain playable tracks without any album grouping. Presence
/// checks must therefore consider visible songs instead of treating albums as
/// the sole proof that the local snapshot is usable.
public enum VisibleLibraryPresencePolicy {
    public static func hasContent(songCount: Int, albumCount: Int) -> Bool {
        songCount > 0 || albumCount > 0
    }
}

/// Chooses a tvOS home hero without assuming every playable song belongs to a
/// visible album. Albumless libraries use a song-backed whole-library hero so
/// the title, artist, count, and play-all controls remain meaningful.
public enum TVHomeHeroPolicy {
    public enum Content: Equatable, Sendable {
        case album
        case song
        case empty
    }

    public static func content(
        totalSongCount: Int,
        albumCount: Int,
        candidateAlbumSongCount: Int
    ) -> Content {
        if albumCount > 0,
           candidateAlbumSongCount > 0 || totalSongCount <= 0 {
            return .album
        }
        if totalSongCount > 0 { return .song }
        return .empty
    }

    public static func displayedSongCount(
        for content: Content,
        totalSongCount: Int,
        candidateAlbumSongCount: Int
    ) -> Int {
        switch content {
        case .album:
            return max(0, candidateAlbumSongCount)
        case .song:
            return max(0, totalSongCount)
        case .empty:
            return 0
        }
    }
}

/// Publishes the durable local snapshot before any remote synchronization can
/// suspend startup, then applies the downloaded snapshot while retaining the
/// local state needed by the caller's merge policy.
public enum LocalFirstSnapshotBootstrap {
    @MainActor
    public static func run<LocalState>(
        publishLocal: () -> LocalState,
        download: () async -> Void,
        applyDownloaded: (LocalState) -> Void
    ) async {
        let localState = publishLocal()
        await download()
        applyDownloaded(localState)
    }
}

/// Keeps the directory browser's display paths separate from connector-native
/// root paths. S3 uses an empty prefix for the bucket root, while the shared
/// browser represents its root breadcrumb as `/`.
public enum SourceDirectorySelectionPolicy {
    /// Path passed to the connector for a path shown by the shared browser.
    public static func connectorPath(
        for sourceType: MusicSourceType,
        browserPath: String
    ) -> String {
        guard sourceType == .s3, browserPath == "/" else { return browserPath }
        return ""
    }

    /// Selectable scan path for the current browser root, when supported.
    /// WebDAV servers can expose playable files directly at their configured
    /// root (for example an OpenList virtual mount), so that root must remain
    /// selectable even when the server has no child directories.
    public static func selectableRootPath(
        for sourceType: MusicSourceType,
        browserPath: String
    ) -> String? {
        guard browserPath.isEmpty || browserPath == "/" else { return nil }
        switch sourceType {
        case .s3: return ""
        case .drime, .webdav: return "/"
        default: return nil
        }
    }

    /// Selecting the S3 bucket root covers all child prefixes, so it is kept
    /// as the sole scope. Lists containing only child paths remain unchanged.
    public static func normalizedSelections(
        _ directories: [String],
        for sourceType: MusicSourceType
    ) -> [String] {
        switch sourceType {
        case .s3 where directories.contains(""):
            return [""]
        case .drime where directories.contains("/"),
             .webdav where directories.contains("/"):
            return ["/"]
        default:
            return directories
        }
    }
}
