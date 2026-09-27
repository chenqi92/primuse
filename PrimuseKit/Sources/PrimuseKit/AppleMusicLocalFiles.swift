import Foundation

/// Audio properties of a file the user imported into Music.app. MusicKit only
/// describes the catalog side of a library row, so these come from the file
/// itself (iTunesLibrary on macOS, the asset on iOS).
public struct AppleMusicLocalFileDetails: Codable, Sendable, Equatable {
    public var fileFormat: AudioFormat?
    public var bitRate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var fileSize: Int64?
    /// The asset itself was inspected. A seed built from the file extension
    /// and the library database alone cannot tell AAC from ALAC inside M4A.
    public var isProbed: Bool

    public init(
        fileFormat: AudioFormat? = nil,
        bitRate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        fileSize: Int64? = nil,
        isProbed: Bool = false
    ) {
        self.fileFormat = fileFormat
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileSize = fileSize
        self.isProbed = isProbed
    }

    /// Probed values win; the library database still fills what the asset
    /// does not report (file size is never available from the asset).
    public func overlaying(_ probed: AppleMusicLocalFileDetails) -> AppleMusicLocalFileDetails {
        AppleMusicLocalFileDetails(
            fileFormat: probed.fileFormat ?? fileFormat,
            bitRate: probed.bitRate ?? bitRate,
            sampleRate: probed.sampleRate ?? sampleRate,
            bitDepth: probed.bitDepth ?? bitDepth,
            fileSize: probed.fileSize ?? fileSize,
            isProbed: probed.isProbed || isProbed
        )
    }
}

public enum AppleMusicLocalFileDetailsPolicy {
    /// Format implied by the extension alone. MPEG-4 audio is left open because
    /// the same `.m4a` holds AAC or Apple Lossless; MusicKit's AAC stays until
    /// the asset has been inspected.
    public static func seedFormat(fileExtension: String) -> AudioFormat? {
        let ext = fileExtension.lowercased()
        guard !["m4a", "m4p", "mp4", "m4b", "m4r"].contains(ext) else { return nil }
        return AudioFormat.from(fileExtension: ext)
    }

    /// Maps a Core Audio format ID (`AudioStreamBasicDescription.mFormatID`)
    /// to the format shown in Primuse. PCM keeps the container's name.
    public static func format(codecID: UInt32, fileExtension: String) -> AudioFormat? {
        switch codecID {
        case fourCC("aac "), fourCC("aach"), fourCC("aacp"), fourCC("aacl"), fourCC("aace"),
             fourCC("aacf"), fourCC("aacg"):
            return .aac
        case fourCC("alac"):
            return .alac
        case fourCC(".mp3"):
            return .mp3
        case fourCC(".mp2"):
            return .mp2
        case fourCC("flac"):
            return .flac
        case fourCC("ac-3"):
            return .ac3
        case fourCC("ec-3"):
            return .eac3
        case fourCC("lpcm"):
            return AudioFormat.from(fileExtension: fileExtension)
        default:
            return seedFormat(fileExtension: fileExtension)
        }
    }

    /// Bit depth a codec actually carries. Lossy codecs report zero bits per
    /// channel; ALAC encodes its source depth in the format flags.
    public static func bitDepth(codecID: UInt32, bitsPerChannel: UInt32, formatFlags: UInt32) -> Int? {
        switch codecID {
        case fourCC("lpcm"), fourCC("flac"):
            return bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        case fourCC("alac"):
            switch formatFlags {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
            }
        default:
            return nil
        }
    }

    /// Replaces MusicKit's placeholder audio properties with the file's own.
    /// Values the file did not report keep whatever the row already had.
    public static func applying(_ details: AppleMusicLocalFileDetails, to song: Song) -> Song {
        var song = song
        if let format = details.fileFormat { song.fileFormat = format }
        if let bitRate = details.bitRate, bitRate > 0 { song.bitRate = bitRate }
        if let sampleRate = details.sampleRate, sampleRate > 0 { song.sampleRate = sampleRate }
        if let bitDepth = details.bitDepth, bitDepth > 0 { song.bitDepth = bitDepth }
        if let fileSize = details.fileSize, fileSize > 0 { song.fileSize = fileSize }
        return song
    }

    public static func fourCC(_ code: String) -> UInt32 {
        code.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// Identity of one imported file as the platform media library reports it.
public struct AppleMusicImportedFile: Sendable, Equatable {
    public let persistentID: UInt64
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?

    public init(
        persistentID: UInt64,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Finds the imported file behind a MusicKit library row. A shared persistent
/// ID is authoritative (iOS device library rows use it as their ID). Rows from
/// the Apple Music cloud API carry only `i.*` IDs, so they fall back to
/// metadata — strictly: title and artist must match, the duration must agree,
/// and the answer must be unique. A wrong match would show another song's
/// lyrics, so ambiguity resolves to no match.
public struct AppleMusicLocalFileMatchIndex: Sendable {
    private var persistentIDsByAlias: [String: Set<UInt64>] = [:]
    private var candidatesByKey: [String: [AppleMusicImportedFile]] = [:]

    public static let durationTolerance: TimeInterval = 2.5

    public init() {}

    public init<Files: Sequence>(_ files: Files) where Files.Element == AppleMusicImportedFile {
        for file in files {
            for alias in AppleMusicLocalFileIdentity.playbackIdentifiers(forPersistentID: file.persistentID) {
                persistentIDsByAlias[alias, default: []].insert(file.persistentID)
            }
            let key = Self.key(title: file.title, artist: file.artist)
            guard !key.isEmpty else { continue }
            candidatesByKey[key, default: []].append(file)
        }
    }

    public var isEmpty: Bool { persistentIDsByAlias.isEmpty }

    public func persistentID(forIdentifiers identifiers: Set<String>) -> UInt64? {
        var matches = Set<UInt64>()
        for identifier in identifiers {
            matches.formUnion(persistentIDsByAlias[identifier] ?? [])
        }
        return matches.count == 1 ? matches.first : nil
    }

    public func persistentID(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) -> UInt64? {
        let key = Self.key(title: title, artist: artist)
        guard !key.isEmpty,
              let duration, duration > 0,
              let candidates = candidatesByKey[key] else { return nil }
        let timed = candidates.filter { candidate in
            guard let other = candidate.duration, other > 0 else { return false }
            return abs(other - duration) <= Self.durationTolerance
        }
        if timed.count == 1 { return timed[0].persistentID }
        // The same recording on two albums: only the album can decide.
        let album = Self.normalize(album)
        guard !album.isEmpty else { return nil }
        let sameAlbum = timed.filter { Self.normalize($0.album) == album }
        return sameAlbum.count == 1 ? sameAlbum[0].persistentID : nil
    }

    private static func key(title: String, artist: String?) -> String {
        let title = normalize(title)
        let artist = normalize(artist)
        guard !title.isEmpty, !artist.isEmpty else { return "" }
        return title + "\u{0}" + artist
    }

    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
