import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Navidrome 0.64 (#5824) re-encodes every historical id as the 22-character
/// base62 form of a 128-bit value. Nearly every song id changes value — all
/// legacy 32-hex MD5 ids and most random nanoids — but the transform is
/// deterministic, so a client can tell that a "new" song is a library row it
/// already has. This mirrors the server's `canonicalID` byte for byte.
public enum NavidromeCanonicalIDPolicy {
    /// Go's `big.Int` alphabet for base 62: digits, lowercase, uppercase.
    private static let digits = Array(
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8
    )
    private static let canonicalLength = 22
    private static let dash = UInt8(ascii: "-")

    /// Unrecognized shapes pass through unchanged, as on the server. `md5` is
    /// only consulted for a 22-character id whose value overflows 128 bits.
    public static func canonicalID(_ id: String, md5: (Data) -> Data) -> String {
        let bytes = Array(id.utf8)
        switch bytes.count {
        case canonicalLength:
            guard let limbs = base62Limbs(bytes), limbs[4] != 0 else { return id }
            let digest = md5(Data(bytes))
            guard digest.count == 16 else { return id }
            return encode(Array(digest))
        case 32:
            guard let value = hexBytes(bytes) else { return id }
            return encode(value)
        case 36:
            let dashes = [8, 13, 18, 23]
            guard dashes.allSatisfy({ bytes[$0] == dash }) else { return id }
            let hex = bytes.enumerated().compactMap { offset, byte in
                dashes.contains(offset) ? nil : byte
            }
            guard let value = hexBytes(hex) else { return id }
            return encode(value)
        default:
            return id
        }
    }

    /// `fmt.Sprintf("%022s", new(big.Int).SetBytes(b).Text(62))`.
    static func encode(_ value: [UInt8]) -> String {
        var limbs = [UInt32](repeating: 0, count: 4)
        for (offset, byte) in value.reversed().enumerated() where offset < 16 {
            limbs[offset / 4] |= UInt32(byte) << (8 * UInt32(offset % 4))
        }
        var output: [UInt8] = []
        while limbs.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for index in limbs.indices.reversed() {
                let current = (remainder << 32) | UInt64(limbs[index])
                limbs[index] = UInt32(current / 62)
                remainder = current % 62
            }
            output.append(digits[Int(remainder)])
        }
        while output.count < canonicalLength { output.append(digits[0]) }
        return String(decoding: output.reversed(), as: UTF8.self)
    }

    /// Little-endian 32-bit limbs; five of them hold any 22-digit value
    /// (62^22 < 2^131). Nil when a byte is outside the alphabet — the server's
    /// `SetString` fails the same way, and a sign prefix passes through there
    /// too.
    private static func base62Limbs(_ bytes: [UInt8]) -> [UInt32]? {
        var limbs = [UInt32](repeating: 0, count: 5)
        for byte in bytes {
            guard let digit = base62Digit(byte) else { return nil }
            var carry = UInt64(digit)
            for index in limbs.indices {
                let product = UInt64(limbs[index]) * 62 + carry
                limbs[index] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
        }
        return limbs
    }

    private static func base62Digit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return UInt32(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return UInt32(byte - UInt8(ascii: "A")) + 36
        default:
            return nil
        }
    }

    private static func hexBytes(_ hex: [UInt8]) -> [UInt8]? {
        guard hex.count == 32 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(16)
        var index = 0
        while index < hex.count {
            guard let high = hexDigit(hex[index]),
                  let low = hexDigit(hex[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

#if canImport(CryptoKit)
public extension NavidromeCanonicalIDPolicy {
    static func canonicalID(_ id: String) -> String {
        canonicalID(id) { Data(Insecure.MD5.hash(data: $0)) }
    }
}
#endif

/// Keeps a library row's song ID when its server renames the song's id.
///
/// A Subsonic row's song ID is derived from `/songs/<server id>.<suffix>`, so
/// a server that re-encodes its ids would otherwise surface every track as a
/// new song and strand play counts, playlists, cached lyrics/artwork and
/// offline copies on rows that then look deleted. Once carried, the row keeps
/// its original song ID while its path follows the server, so every later
/// scan must carry it again by the server id recorded in that path.
public enum SubsonicSongIdentityCarryPolicy {
    private static let pathPrefix = "/songs/"

    public static func serverSongID(fromPath path: String) -> String? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let name = String(path.dropFirst(pathPrefix.count))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let id = (name as NSString).deletingPathExtension
        return id.isEmpty ? nil : id
    }

    /// Existing rows keyed by the server song id in their path and by that
    /// id's Navidrome canonical form. A key claimed by two rows (the library
    /// already holds a duplicate) is dropped rather than guessed.
    public static func songIDsByServerSongID(
        _ songs: [Song],
        canonicalID: (String) -> String
    ) -> [String: String] {
        var result: [String: String] = [:]
        var ambiguous = Set<String>()
        func claim(_ key: String, for songID: String) {
            guard !ambiguous.contains(key) else { return }
            if let current = result[key], current != songID {
                result[key] = nil
                ambiguous.insert(key)
            } else {
                result[key] = songID
            }
        }
        for song in songs {
            guard let serverID = serverSongID(fromPath: song.filePath) else { continue }
            claim(serverID, for: song.id)
            let canonical = canonicalID(serverID)
            if canonical != serverID { claim(canonical, for: song.id) }
        }
        return result
    }

    /// The song ID an incoming row must keep, or nil when the connector's own
    /// ID already names a library row (or no row matches).
    public static func carriedSongID(
        for incoming: Song,
        isExistingSongID: (String) -> Bool,
        songIDsByServerSongID: [String: String]
    ) -> String? {
        guard !isExistingSongID(incoming.id),
              let serverID = serverSongID(fromPath: incoming.filePath),
              let carried = songIDsByServerSongID[serverID],
              carried != incoming.id,
              isExistingSongID(carried) else { return nil }
        return carried
    }

    /// True when only the server id in the path changed, exactly as the
    /// Navidrome migration re-encodes it — the same object, the same bytes.
    public static func isCanonicalRekey(
        previousPath: String,
        currentPath: String,
        canonicalID: (String) -> String
    ) -> Bool {
        guard let previousID = serverSongID(fromPath: previousPath),
              let currentID = serverSongID(fromPath: currentPath),
              previousID != currentID,
              (previousPath as NSString).pathExtension.lowercased()
                == (currentPath as NSString).pathExtension.lowercased() else {
            return false
        }
        return canonicalID(previousID) == currentID
    }

    /// Navidrome cover art ids read `<kind>-<id>_<updated>`. The migration
    /// re-encodes only `<id>`, so the artwork behind the reference is the one
    /// already cached.
    public static func isCanonicalCoverArtRekey(
        previousReference: String,
        currentReference: String,
        canonicalID: (String) -> String
    ) -> Bool {
        guard let previous = coverArtParts(previousReference),
              let current = coverArtParts(currentReference),
              previous.head == current.head,
              previous.tail == current.tail,
              previous.id != current.id else { return false }
        return canonicalID(String(previous.id)) == current.id
    }

    private static func coverArtParts(
        _ reference: String
    ) -> (head: Substring, id: Substring, tail: Substring)? {
        let nameStart = reference.lastIndex(of: "/").map { reference.index(after: $0) }
            ?? reference.startIndex
        guard let dash = reference[nameStart...].firstIndex(of: "-") else { return nil }
        let idStart = reference.index(after: dash)
        let idEnd = reference[idStart...].lastIndex(of: "_") ?? reference.endIndex
        guard idStart < idEnd else { return nil }
        return (reference[..<idStart], reference[idStart..<idEnd], reference[idEnd...])
    }
}
