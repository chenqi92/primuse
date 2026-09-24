import Foundation

/// The few song fields companion matching looks at.
public struct KaraokeCompanionCandidate: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String?
    public var albumTitle: String?
    /// Seconds; 0 or less means unknown.
    public var duration: TimeInterval
    /// Path of the file within its source, used for the folder and for
    /// markers that only appear in the file name.
    public var filePath: String
    public var sourceID: String

    public init(
        id: String,
        title: String,
        artistName: String?,
        albumTitle: String?,
        duration: TimeInterval,
        filePath: String,
        sourceID: String
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.filePath = filePath
        self.sourceID = sourceID
    }

    var fileStem: String {
        let name = (filePath as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    var folder: String {
        sourceID + "/" + (filePath as NSString).deletingLastPathComponent
    }
}

/// Pairs a sung track with its instrumental ("伴奏", "off vocal",
/// "Instrumental", "MR"…) living elsewhere in the library, in either
/// direction. A real backing track beats any vocal removal.
public enum KaraokeCompanionPolicy {
    /// Lower-cased markers. Latin ones only count as whole words.
    static let markers: [String] = [
        "instrumental", "off vocal", "off-vocal", "offvocal",
        "karaoke", "backing track", "minus one",
        "伴奏", "纯伴奏", "純伴奏", "消音版", "伴唱版",
        "カラオケ", "オフボーカル", "オリジナル・カラオケ",
        "반주", "인스트루멘탈",
    ]

    /// Largest duration difference still treated as the same arrangement.
    static func durationTolerance(_ duration: TimeInterval) -> TimeInterval {
        max(3, duration * 0.02)
    }

    /// Whether the title or file name marks an instrumental version.
    public static func isInstrumental(_ song: KaraokeCompanionCandidate) -> Bool {
        containsMarker(song.title) || containsMarker(song.fileStem)
    }

    /// Abbreviations that are ordinary words elsewhere ("Mr. Brightside"):
    /// only a marker when they end the text or fill a bracket.
    static let trailingMarkers: [String] = ["mr", "inst", "inst."]

    static func containsMarker(_ text: String) -> Bool {
        let folded = text.lowercased()
        let trimmed = folded.trimmingCharacters(
            in: CharacterSet(charactersIn: " )]）】」>》.").union(.whitespaces)
        )
        for marker in trailingMarkers where trimmed.hasSuffix(marker.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            let stem = marker.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let before = trimmed.dropLast(stem.count).last
            if before.map({ !$0.isLetter && !$0.isNumber }) ?? true { return true }
        }
        return markers.contains { marker in
            guard let range = folded.range(of: marker) else { return false }
            guard marker.unicodeScalars.allSatisfy(\.isASCII) else { return true }
            return isWordBoundary(folded, range)
        }
    }

    private static func isWordBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
        let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
        func isWordCharacter(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber
        }
        return !isWordCharacter(before) && !isWordCharacter(after)
    }

    /// The title with version markers, bracketed qualifiers and punctuation
    /// removed, for comparing a song with its instrumental.
    public static func baseTitle(_ title: String) -> String {
        var text = title.lowercased()
        // Drop bracketed segments that carry a marker: "(Instrumental)",
        // "【伴奏】", "[Off Vocal Ver.]".
        let pairs: [(Character, Character)] = [
            ("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("「", "」"), ("<", ">"), ("《", "》"),
        ]
        for (open, close) in pairs {
            var result = ""
            var segment = ""
            var depth = 0
            for character in text {
                if character == open {
                    depth += 1
                    if depth == 1 { segment = ""; continue }
                }
                if depth > 0 {
                    if character == close {
                        depth -= 1
                        if depth == 0 {
                            if !containsMarker(segment) {
                                result += " " + segment + " "
                            }
                            continue
                        }
                    }
                    segment.append(character)
                } else {
                    result.append(character)
                }
            }
            if depth > 0 { result += " " + segment }
            text = result
        }
        // "Song - Instrumental", "Song／伴奏": cut at the separator when the
        // tail is a marker.
        for separator in [" - ", " – ", " — ", "-", "／", "/", "~", "～"] {
            if let range = text.range(of: separator, options: .backwards),
               containsMarker(String(text[range.upperBound...])) {
                text = String(text[..<range.lowerBound])
            }
        }
        // A bare trailing marker: "Song Instrumental", "歌名伴奏".
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        text = trimmedText
        for marker in (markers + ["mr", "inst"]).sorted(by: { $0.count > $1.count }) where text.hasSuffix(marker) {
            let candidate = String(text.dropLast(marker.count))
            let ascii = marker.unicodeScalars.allSatisfy(\.isASCII)
            if !ascii || candidate.last.map({ !$0.isLetter && !$0.isNumber }) ?? false {
                text = candidate
                break
            }
        }
        return String(text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// Lower-cased letters and digits only.
    static func folded(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                let value = scalar.value
                if (0x30...0x39).contains(value) || (0x61...0x7A).contains(value) {
                    result.append(scalar)
                } else if (0x41...0x5A).contains(value) {
                    result.append(Unicode.Scalar(value + 0x20)!)
                }
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                result.append(contentsOf: String(scalar).lowercased().unicodeScalars)
            }
        }
        return String(result)
    }

    static func normalizedName(_ name: String?) -> String {
        guard let name else { return "" }
        return String(name.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// The instrumental version of `song`, if the library holds one.
    public static func instrumental(
        for song: KaraokeCompanionCandidate,
        in library: [KaraokeCompanionCandidate]
    ) -> KaraokeCompanionCandidate? {
        guard !isInstrumental(song) else { return nil }
        return bestMatch(for: song, in: library, wantInstrumental: true)
    }

    /// The sung original of an instrumental `song`, for its lyrics.
    public static func original(
        for song: KaraokeCompanionCandidate,
        in library: [KaraokeCompanionCandidate]
    ) -> KaraokeCompanionCandidate? {
        guard isInstrumental(song) else { return nil }
        return bestMatch(for: song, in: library, wantInstrumental: false)
    }

    private static func bestMatch(
        for song: KaraokeCompanionCandidate,
        in library: [KaraokeCompanionCandidate],
        wantInstrumental: Bool
    ) -> KaraokeCompanionCandidate? {
        let base = baseTitle(song.title)
        guard !base.isEmpty else { return nil }
        let artist = normalizedName(song.artistName)
        let album = normalizedName(song.albumTitle)

        var best: (candidate: KaraokeCompanionCandidate, rank: Int, delta: TimeInterval)?
        for candidate in library where candidate.id != song.id {
            // Cheap screen first: a companion's title starts with the same
            // name. Only the handful that pass pay for full marker parsing.
            guard folded(candidate.title).hasPrefix(base),
                  isInstrumental(candidate) == wantInstrumental,
                  baseTitle(candidate.title) == base else { continue }
            let sameFolder = candidate.folder == song.folder
            let sameAlbum = !album.isEmpty && normalizedName(candidate.albumTitle) == album
            let candidateArtist = normalizedName(candidate.artistName)
            let sameArtist = !artist.isEmpty && !candidateArtist.isEmpty
                && (candidateArtist == artist
                    || candidateArtist.contains(artist)
                    || artist.contains(candidateArtist))
            let artistConflict = !artist.isEmpty && !candidateArtist.isEmpty && !sameArtist
            guard !artistConflict else { continue }

            let delta: TimeInterval
            if song.duration > 0, candidate.duration > 0 {
                delta = abs(song.duration - candidate.duration)
                guard delta <= durationTolerance(max(song.duration, candidate.duration)) else { continue }
            } else {
                // Without durations only a shared folder or album is trusted.
                guard sameFolder || sameAlbum else { continue }
                delta = .infinity
            }
            guard sameFolder || sameAlbum || sameArtist else { continue }

            let rank = sameFolder ? 3 : (sameAlbum ? 2 : 1)
            if let current = best {
                if rank > current.rank || (rank == current.rank && delta < current.delta) {
                    best = (candidate, rank, delta)
                }
            } else {
                best = (candidate, rank, delta)
            }
        }
        return best?.candidate
    }
}
