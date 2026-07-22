import Foundation
import CoreFoundation

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
            "Unsupported JSON value of type \(typeName)"
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
    public static let supportedLyricsExtensions = ["lrc"]
    public static let supportedMusicVideoExtensions = ["mp4", "m4v", "mov"]
    public static let folderCoverNames = ["cover", "folder", "album", "front", "artwork"]

    /// Note: `.mp4` is intentionally excluded — it's primarily a video
    /// container, and the SFB AAC-in-MP4 decoder is unreliable for the
    /// kind of mp4 a user typically drops in their music folder (often
    /// extracted-from-video files with non-standard atom layout). Audio
    /// MP4 files should use `.m4a`. Including `.mp4` here led to mid-stream
    /// PCM decode errors that auto-skipped 25%+ of cloud-drive scans.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "alac",
        "ape", "dsf", "dff", "ogg", "opus", "wma", "wv"
    ]
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

    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        playlistID == systemPlaylistID
            || playlistID.hasPrefix(userPlaylistIDPrefix)
    }
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
