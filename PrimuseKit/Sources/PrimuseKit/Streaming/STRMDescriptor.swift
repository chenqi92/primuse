import CryptoKit
import Foundation

/// A parsed `.strm` wrapper. The target is intentionally runtime-only: callers
/// must not persist it in `Song`, because OpenList and similar services often
/// emit short-lived signed URLs containing credentials in the query string.
public struct STRMDescriptor: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case remote(URL)
        case sourcePath(String)
    }

    public let target: Target
    public let format: AudioFormat
    public let duration: TimeInterval?
    public let title: String?
    public let artist: String?
    public let contentRevision: String

    public init(
        target: Target,
        format: AudioFormat,
        duration: TimeInterval?,
        title: String?,
        artist: String?,
        contentRevision: String
    ) {
        self.target = target
        self.format = format
        self.duration = duration
        self.title = title
        self.artist = artist
        self.contentRevision = contentRevision
    }
}

public enum STRMDescriptorError: Error, Sendable, Equatable {
    case empty
    case tooLarge(actualByteCount: Int, maximumByteCount: Int)
    case unsupportedEncoding
    case invalidTarget
    case unsupportedFormat
}

/// Strict, allocation-bounded parser for Kodi/OpenList-style `.strm` files.
public enum STRMDescriptorParser {
    public static let maximumByteCount = 64 * 1024

    public static func parse(_ data: Data) throws -> STRMDescriptor {
        guard !data.isEmpty else { throw STRMDescriptorError.empty }
        guard data.count <= maximumByteCount else {
            throw STRMDescriptorError.tooLarge(
                actualByteCount: data.count,
                maximumByteCount: maximumByteCount
            )
        }
        guard let text = decode(data) else {
            throw STRMDescriptorError.unsupportedEncoding
        }

        var duration: TimeInterval?
        var label: String?
        var declaredMIMEType: String?
        var targetCandidates: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                let payload = String(line.dropFirst("#EXTINF:".count))
                let pieces = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                if let seconds = pieces.first.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }),
                   seconds > 0 {
                    duration = seconds
                }
                if pieces.count == 2 {
                    let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { label = value }
                }
                continue
            }
            if line.uppercased().hasPrefix("#KODIPROP:MIMETYPE=") {
                declaredMIMEType = String(line.dropFirst("#KODIPROP:MIMETYPE=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if line.hasPrefix("#") { continue }
            targetCandidates.append(line)
        }

        guard !targetCandidates.isEmpty else { throw STRMDescriptorError.empty }
        var selected: (target: STRMDescriptor.Target, format: AudioFormat)?
        var hadSyntacticallyValidTarget = false
        for rawTarget in targetCandidates {
            guard let target = parsedTarget(rawTarget) else { continue }
            hadSyntacticallyValidTarget = true
            guard let format = inferredFormat(
                target: rawTarget,
                declaredMIMEType: declaredMIMEType
            ) else { continue }
            selected = (target, format)
            break
        }
        guard let selected else {
            throw hadSyntacticallyValidTarget
                ? STRMDescriptorError.unsupportedFormat
                : STRMDescriptorError.invalidTarget
        }

        let identity = parseLabel(label)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return STRMDescriptor(
            target: selected.target,
            format: selected.format,
            duration: duration,
            title: identity.title,
            artist: identity.artist,
            contentRevision: "strm:\(digest)"
        )
    }

    private static func parsedTarget(_ rawTarget: String) -> STRMDescriptor.Target? {
        if let components = URLComponents(string: rawTarget), let scheme = components.scheme {
            guard ["http", "https"].contains(scheme.lowercased()),
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  let url = components.url else { return nil }
            return .remote(url)
        }
        guard let normalized = STRMSourcePathResolver.normalizedReference(rawTarget) else {
            return nil
        }
        return .sourcePath(normalized)
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .utf16)
    }

    private static func inferredFormat(
        target: String,
        declaredMIMEType: String?
    ) -> AudioFormat? {
        if let fromMIME = declaredMIMEType.flatMap(format(forMIMEType:)) {
            return fromMIME
        }
        guard let components = URLComponents(string: target) else {
            return AudioFormat.from(fileExtension: (target as NSString).pathExtension)
        }
        if let direct = AudioFormat.from(fileExtension: (components.path as NSString).pathExtension) {
            return direct
        }
        for item in components.queryItems ?? [] where ["filename", "file", "name", "path"].contains(item.name.lowercased()) {
            guard let value = item.value else { continue }
            if let format = AudioFormat.from(fileExtension: (value as NSString).pathExtension) {
                return format
            }
        }
        return nil
    }

    private static func format(forMIMEType value: String) -> AudioFormat? {
        switch value.lowercased().split(separator: ";", maxSplits: 1).first {
        case "audio/mpeg": return .mp3
        case "audio/aac": return .aac
        case "audio/mp4", "audio/x-m4a": return .m4a
        case "audio/flac", "audio/x-flac": return .flac
        case "audio/wav", "audio/wave", "audio/x-wav": return .wav
        case "audio/aiff", "audio/x-aiff": return .aiff
        case "audio/ogg": return .ogg
        case "audio/opus": return .opus
        case "audio/x-ape": return .ape
        default: return nil
        }
    }

    private static func parseLabel(_ value: String?) -> (artist: String?, title: String?) {
        guard let value else { return (nil, nil) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        guard let range = trimmed.range(of: "\\s+[–—-]\\s+", options: .regularExpression) else {
            return (nil, trimmed)
        }
        let artist = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let title = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (artist.isEmpty ? nil : artist, title.isEmpty ? nil : title)
    }
}

/// Separates the cheap wrapper fingerprint from the descriptor content hash.
/// Scanners can therefore skip reopening an unchanged `.strm` while still
/// detecting regenerated links when the provider exposes a revision or mtime.
public enum STRMRevision {
    public static func songRevision(
        wrapperRevision: String?,
        wrapperSize: Int64,
        wrapperModifiedDate: Date?,
        contentRevision: String
    ) -> String {
        let fingerprint = wrapperFingerprint(
            revision: wrapperRevision,
            size: wrapperSize,
            modifiedDate: wrapperModifiedDate
        ) ?? "volatile"
        return "strm-wrapper:\(fingerprint):\(contentRevision)"
    }

    public static func wrapperMatches(
        songRevision: String?,
        wrapperRevision: String?,
        wrapperSize: Int64,
        wrapperModifiedDate: Date?
    ) -> Bool {
        guard let fingerprint = wrapperFingerprint(
            revision: wrapperRevision,
            size: wrapperSize,
            modifiedDate: wrapperModifiedDate
        ), let songRevision else { return false }
        return songRevision.hasPrefix("strm-wrapper:\(fingerprint):")
    }

    private static func wrapperFingerprint(
        revision: String?,
        size: Int64,
        modifiedDate: Date?
    ) -> String? {
        let source: String
        if let revision, !revision.isEmpty {
            source = "revision:\(revision)"
        } else if let modifiedDate {
            source = "stat:\(size):\(Int64(modifiedDate.timeIntervalSince1970 * 1_000))"
        } else {
            return nil
        }
        return SHA256.hash(data: Data(source.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Normalizes a descriptor's same-source reference without allowing it to
/// escape the connector root. Resolution remains purely path based; credentials
/// are never copied from the source connector to an external host.
public enum STRMSourcePathResolver {
    public static func resolve(_ reference: String, relativeTo descriptorPath: String) -> String? {
        guard let reference = normalizedReference(reference) else { return nil }
        if reference.hasPrefix("/") { return reference }
        let parent = (descriptorPath as NSString).deletingLastPathComponent
        let combined = parent.isEmpty || parent == "." ? reference : (parent as NSString).appendingPathComponent(reference)
        return normalize(combined, preserveLeadingSlash: descriptorPath.hasPrefix("/"))
    }

    static func normalizedReference(_ reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              URLComponents(string: trimmed)?.scheme == nil else { return nil }
        if trimmed.hasPrefix("/") {
            return normalize(trimmed, preserveLeadingSlash: true)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "~" }) else { return nil }
        // Leading `..` is meaningful until the descriptor's own directory is
        // known. `resolve(_:relativeTo:)` performs the containment check.
        return components.joined(separator: "/")
    }

    private static func normalize(_ path: String, preserveLeadingSlash: Bool) -> String? {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                guard component != "~" else { return nil }
                components.append(component)
            }
        }
        guard !components.isEmpty else { return preserveLeadingSlash ? "/" : nil }
        let joined = components.joined(separator: "/")
        return preserveLeadingSlash ? "/" + joined : joined
    }
}

/// Resolves OpenList's optional prefix-free `/d/...` descriptors against the
/// origin that served the `.strm` wrapper. The WebDAV `/dav` base path is
/// intentionally discarded. No credentials or headers are copied.
public enum OpenListSTRMTargetResolver {
    public static func resolve(_ reference: String, wrapperURL: URL) -> URL? {
        guard reference == "/d" || reference.hasPrefix("/d/"),
              let wrapper = URLComponents(url: wrapperURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(wrapper.scheme?.lowercased() ?? ""),
              wrapper.host?.isEmpty == false,
              wrapper.user == nil,
              wrapper.password == nil,
              let referenceComponents = URLComponents(string: reference),
              referenceComponents.scheme == nil,
              referenceComponents.host == nil,
              referenceComponents.fragment == nil,
              !referenceComponents.path.split(separator: "/").contains("..") else {
            return nil
        }

        var target = URLComponents()
        target.scheme = wrapper.scheme
        target.host = wrapper.host
        target.port = wrapper.port
        target.path = referenceComponents.path
        target.percentEncodedQuery = referenceComponents.percentEncodedQuery
        return target.url
    }
}
