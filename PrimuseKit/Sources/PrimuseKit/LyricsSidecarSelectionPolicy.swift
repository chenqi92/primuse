import Foundation

/// Chooses which same-name lyric sidecar a song reads from, and which file a
/// save may replace. The two questions have different answers: Primuse reads
/// several formats but only ever serializes LRC or TTML, so a `.vtt`, `.srt`
/// or `.lys` document is authoritative for reading and untouchable for
/// writing. Keeping the decision here rather than inside a connector makes it
/// testable without a live source.
public enum LyricsSidecarSelectionPolicy {
    public enum Selection: Equatable, Sendable {
        case none
        /// Index into the candidate names that were passed in.
        case item(Int)
        /// Two writable documents with the same base name: a save cannot tell
        /// which one the user meant, so it must not guess.
        case conflict
    }

    /// Extensions that also match under the subtitle ecosystem's
    /// `<base>.<lang>.<ext>` naming: yt-dlp writes `Title [id].en.vtt`, media
    /// servers expect `name.<lang>.srt`, Chinese subtitle groups ship
    /// `.chs.srt`. The convention belongs to subtitles alone — leaving `.lrc`,
    /// `.ttml` and the word-timed formats out of it keeps every
    /// language-tagged document read-only by construction, so a save still
    /// only ever touches the exact-name `.lrc` or `.ttml`.
    public static let languageTaggedExtensions = ["vtt", "srt"]

    /// Whether sidecar writeback may serialize into this file at all.
    public static func isWritableDocument(fileName: String) -> Bool {
        PrimuseConstants.supportedLyricsExtensions.contains(fileExtension(of: fileName))
    }

    /// The song's base name and language tag inside `<stem>.<tag>.<ext>`. The
    /// stem is split at its LAST dot, and the tag has to look like a language
    /// before it is believed: `01. Song.vtt` would otherwise be read as base
    /// `01` with tag ` Song`, and `Song.Remix.srt` belongs to a song whose
    /// name really does end in `.Remix`.
    public static func languageTaggedComponents(
        ofSidecarNamed fileName: String
    ) -> (baseName: String, tag: String)? {
        guard languageTaggedExtensions.contains(fileExtension(of: fileName)) else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        guard let separator = stem.lastIndex(of: ".") else { return nil }
        let baseName = String(stem[stem.startIndex..<separator])
        let tag = String(stem[stem.index(after: separator)...])
        guard !baseName.isEmpty, isPlausibleLanguageTag(tag) else { return nil }
        return (baseName, tag)
    }

    /// Which of a song's language-tagged documents to read, as an index into
    /// `tags`. The ranking is total, so the same directory always resolves to
    /// the same file.
    public static func bestLanguageTagIndex(
        tags: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Int? {
        guard !tags.isEmpty else { return nil }
        let preferred = preferredLanguages.map(normalizedLanguageTag)
        var bestKey: (Int, Int, Int, String)?
        var bestIndex: Int?
        for (index, tag) in tags.enumerated() {
            let normalized = normalizedLanguageTag(tag)
            let match = preferredMatch(ofNormalized: normalized, in: preferred)
            // An `-orig` track is the language actually sung; its siblings are
            // machine translations, and Primuse puts its own translation layer
            // on top of the original rather than reading a translated one.
            let key = (
                marksOriginalTrack(tag) ? 0 : 1,
                match?.rank ?? Int.max,
                match?.strength ?? Int.max,
                normalized
            )
            if let bestKey, !(key < bestKey) { continue }
            bestKey = key
            bestIndex = index
        }
        return bestIndex
    }

    /// The machine-translated companion of an `-orig` track, as an index into
    /// `names`. yt-dlp writes the sung language plus one track per requested
    /// language off the same cue list, so the translated track belongs under
    /// the original's lines rather than beside it as a second document.
    public static func translationTrack(
        forPrimary primaryName: String,
        baseName: String,
        names: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Int? {
        guard let primary = languageTaggedComponents(ofSidecarNamed: primaryName),
              primary.baseName.caseInsensitiveCompare(baseName) == .orderedSame,
              marksOriginalTrack(primary.tag) else { return nil }

        var audioStems: Set<String> = []
        var candidates: [(index: Int, tag: String, stem: String)] = []
        for (index, name) in names.enumerated() {
            let fileExtension = fileExtension(of: name)
            if PrimuseConstants.supportedAudioExtensions.contains(fileExtension)
                || PrimuseConstants.supportedStreamDescriptorExtensions.contains(fileExtension) {
                audioStems.insert((name as NSString).deletingPathExtension.lowercased())
                continue
            }
            guard name.caseInsensitiveCompare(primaryName) != .orderedSame,
                  let components = languageTaggedComponents(ofSidecarNamed: name),
                  components.baseName.caseInsensitiveCompare(baseName) == .orderedSame else {
                continue
            }
            candidates.append((
                index: index,
                tag: components.tag,
                stem: (name as NSString).deletingPathExtension.lowercased()
            ))
        }
        // Same guard as the main document: `Track.it.vtt` beside
        // `Track.it.flac` is that song's own sidecar, not a translation.
        let usable = candidates.filter { !audioStems.contains($0.stem) }
        guard let choice = translationTrackIndex(
            originalTag: primary.tag,
            tags: usable.map(\.tag),
            preferredLanguages: preferredLanguages
        ) else { return nil }
        return usable[choice].index
    }

    /// The tag in the spelling `LyricManualTranslation.languageCode` is
    /// compared in: `LyricTranslationGroupingPolicy.languageIdentity` reads
    /// the script off it, so `zh-CN` has to arrive as `zh-Hans` and not as a
    /// region.
    public static func translationLanguageCode(forTag tag: String) -> String? {
        LyricLanguageCodePolicy.canonicalIdentifier(normalizedLanguageTag(tag))
    }

    /// Whether a language tag names the track that was actually sung.
    public static func marksOriginalTrack(_ tag: String) -> Bool {
        tag.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .hasSuffix(originalTrackSuffix)
    }

    /// Shared by the file-name and the per-directory entry point: ranks the
    /// tracks that could translate `originalTag` and returns the winner as an
    /// index into `tags`.
    static func translationTrackIndex(
        originalTag: String,
        tags: [String],
        preferredLanguages: [String]
    ) -> Int? {
        let original = primarySubtag(of: normalizedLanguageTag(originalTag))
        let preferred = preferredLanguages.map(normalizedLanguageTag)
        var bestKey: (Int, Int, String)?
        var bestIndex: Int?
        for (index, tag) in tags.enumerated() {
            let normalized = normalizedLanguageTag(tag)
            // `en-orig` next to `en-GB` is the same words twice; a translation
            // has to be in another language to be one at all.
            guard primarySubtag(of: normalized) != original,
                  // A translation nobody in this household reads is worth
                  // nothing, so the lexicographic fallback that always picks
                  // *some* main document deliberately has no counterpart here.
                  let match = preferredMatch(ofNormalized: normalized, in: preferred) else {
                continue
            }
            let key = (match.rank, match.strength, normalized)
            if let bestKey, !(key < bestKey) { continue }
            bestKey = key
            bestIndex = index
        }
        return bestIndex
    }

    /// The song's current lyric document among its same-name siblings.
    public static func currentDocument(
        baseName: String,
        names: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Selection {
        var writable: [Int] = []
        var readOnly: [Int] = []
        for (index, name) in names.enumerated() {
            let name = name as NSString
            guard name.deletingPathExtension.caseInsensitiveCompare(baseName) == .orderedSame,
                  PrimuseConstants.readableLyricsExtensions.contains(
                    name.pathExtension.lowercased()
                  ) else { continue }
            if isWritableDocument(fileName: name as String) {
                writable.append(index)
            } else {
                readOnly.append(index)
            }
        }

        if !writable.isEmpty {
            // An edited or scraped document outranks whatever the source
            // shipped, and a second writable sibling is the ambiguity this
            // policy has always refused.
            guard writable.count == 1, let index = writable.first else { return .conflict }
            return .item(index)
        }
        // Nothing here will ever be overwritten, and `song.vtt` next to
        // `song.srt` is the ordinary output of a transcription tool, so read
        // priority decides instead of refusing to read either one.
        let best = readOnly.min { left, right in
            let leftRank = readPriority(of: names[left])
            let rightRank = readPriority(of: names[right])
            if leftRank != rightRank { return leftRank < rightRank }
            return names[left] < names[right]
        }
        guard let best else {
            // Nothing carries the song's exact name, so the language suffix is
            // consulted last — never before it, because an exact-name
            // `song.ttml` or `song.lrc` is what the user edited and
            // `song.en.vtt` only what came with the download.
            return languageTaggedDocument(
                baseName: baseName,
                names: names,
                preferredLanguages: preferredLanguages
            )
        }
        return .item(best)
    }

    /// The writable document that replaces a read-only one. A save creates
    /// `<base>.ttml` or `<base>.lrc` next to the source document instead of
    /// overwriting it. Returns nil when `targetPath` does not actually end in
    /// the document's extension, because the caller then has no address it may
    /// safely rewrite.
    public static func writableReplacement(
        targetPath: String,
        fileName: String,
        baseName: String? = nil
    ) -> (targetPath: String, fileName: String)? {
        let replacementName = writableFileName(replacing: fileName, baseName: baseName)
        // A language-tagged document drops its tag, so the whole name has to
        // go: `song.en.vtt` becomes `song.ttml`, never `song.en.ttml`.
        if baseName != nil,
           !fileName.isEmpty,
           targetPath.count >= fileName.count,
           targetPath.suffix(fileName.count).caseInsensitiveCompare(fileName) == .orderedSame {
            return (
                targetPath: String(targetPath.dropLast(fileName.count)) + replacementName,
                fileName: replacementName
            )
        }
        let name = fileName as NSString
        let suffix = ".\(name.pathExtension)"
        guard suffix.count > 1,
              targetPath.count >= suffix.count,
              targetPath.suffix(suffix.count).caseInsensitiveCompare(suffix) == .orderedSame else {
            return nil
        }
        return (
            targetPath: String(targetPath.dropLast(suffix.count))
                + "." + writableExtension(replacing: fileName),
            fileName: replacementName
        )
    }

    /// The name a save uses next to a read-only document. `baseName` is the
    /// song's own base name; it has to be passed in rather than derived,
    /// because stripping what looks like a tag would rename the sidecar of a
    /// song genuinely called `A.en`.
    public static func writableFileName(
        replacing fileName: String,
        baseName: String? = nil
    ) -> String {
        let stem = (baseName?.isEmpty == false ? baseName : nil)
            ?? (fileName as NSString).deletingPathExtension
        return stem + "." + writableExtension(replacing: fileName)
    }

    /// The format a save uses beside a read-only document. Subtitle cues carry
    /// a window per line and the word-timed formats carry explicit word ends;
    /// LRC holds neither, and a save that had to go through LRC would be kept
    /// in Primuse's local store instead of reaching the source. TTML keeps all
    /// of it. Enhanced LRC is LRC already, so it stays with `.lrc`.
    public static func writableExtension(replacing fileName: String) -> String {
        fileExtension(of: fileName) == "elrc" ? "lrc" : "ttml"
    }

    private static func fileExtension(of fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private static func readPriority(of fileName: String) -> Int {
        PrimuseConstants.readableLyricsExtensions
            .firstIndex(of: fileExtension(of: fileName))
            ?? PrimuseConstants.readableLyricsExtensions.count
    }

    private static func languageTaggedDocument(
        baseName: String,
        names: [String],
        preferredLanguages: [String]
    ) -> Selection {
        var audioStems: Set<String> = []
        var candidates: [(index: Int, tag: String, stem: String)] = []
        for (index, name) in names.enumerated() {
            let fileExtension = fileExtension(of: name)
            if PrimuseConstants.supportedAudioExtensions.contains(fileExtension)
                || PrimuseConstants.supportedStreamDescriptorExtensions.contains(fileExtension) {
                audioStems.insert((name as NSString).deletingPathExtension.lowercased())
                continue
            }
            guard let components = languageTaggedComponents(ofSidecarNamed: name),
                  components.baseName.caseInsensitiveCompare(baseName) == .orderedSame else {
                continue
            }
            candidates.append((
                index: index,
                tag: components.tag,
                stem: (name as NSString).deletingPathExtension.lowercased()
            ))
        }
        // `Track.it.vtt` beside `Track.it.flac` is that song's own exact-name
        // sidecar, not the Italian subtitle of `Track.flac`.
        let usable = candidates.filter { !audioStems.contains($0.stem) }
        guard let choice = bestLanguageTagIndex(
            tags: usable.map(\.tag),
            preferredLanguages: preferredLanguages
        ) else { return .none }
        // Every candidate here is read-only, so there is no save to make
        // ambiguous and nothing to refuse.
        return .item(usable[choice].index)
    }

    // MARK: - Language tags

    private static let originalTrackSuffix = "-orig"

    nonisolated(unsafe) private static let languageTagPattern =
        /[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}/

    /// Built once: the list is several hundred entries and a directory asks
    /// this question for every subtitle it holds.
    private static let isoLanguageSubtags: Set<String> =
        Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier.lowercased() })

    /// Not ISO codes, but what Chinese subtitle groups have always written.
    private static let communityLanguageSubtags: Set<String> = ["chs", "cht"]

    /// Normalization aliases. The bibliographic three-letter codes are here
    /// for a preferred-language list that carries them; a file name only gets
    /// past `isPlausibleLanguageTag` with an ISO code or `chs`/`cht`.
    private static let languageSubtagAliases: [String: String] = [
        "chs": "zh-hans", "cht": "zh-hant",
        "chi": "zh", "zho": "zh", "cmn": "zh",
        "eng": "en", "jpn": "ja", "kor": "ko",
        "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
        "spa": "es", "ita": "it", "rus": "ru", "por": "pt",
    ]

    /// A region-only Chinese tag names its script implicitly, and the script
    /// is what decides whether a reader can follow the text.
    private static let chineseScriptByRegion: [String: String] = [
        "cn": "hans", "sg": "hans", "my": "hans",
        "tw": "hant", "hk": "hant", "mo": "hant",
    ]

    private static func isPlausibleLanguageTag(_ tag: String) -> Bool {
        guard tag.wholeMatch(of: languageTagPattern) != nil else { return false }
        let primary = primarySubtag(of: tag.lowercased())
        return isoLanguageSubtags.contains(primary)
            || communityLanguageSubtags.contains(primary)
    }

    /// The first preferred language this tag answers to, if any.
    private static func preferredMatch(
        ofNormalized normalized: String,
        in preferred: [String]
    ) -> (rank: Int, strength: Int)? {
        for (position, candidate) in preferred.enumerated() {
            guard let match = matchStrength(of: normalized, against: candidate) else { continue }
            return (position, match)
        }
        return nil
    }

    private static func normalizedLanguageTag(_ tag: String) -> String {
        var value = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if value.hasSuffix(originalTrackSuffix) {
            value = String(value.dropLast(originalTrackSuffix.count))
        }
        var subtags = value.split(separator: "-").map(String.init)
        guard let primary = subtags.first else { return value }
        if let alias = languageSubtagAliases[primary] {
            subtags.replaceSubrange(0..<1, with: alias.split(separator: "-").map(String.init))
        }
        if subtags.count == 2, subtags[0] == "zh", let script = chineseScriptByRegion[subtags[1]] {
            subtags[1] = script
        }
        return subtags.joined(separator: "-")
    }

    /// 0 when the two tags name the same variant — or one is the other cut at
    /// a subtag boundary — 1 when only the language agrees, nil when they are
    /// different languages.
    private static func matchStrength(of tag: String, against preferred: String) -> Int? {
        if tag == preferred { return 0 }
        if tag.hasPrefix(preferred + "-") || preferred.hasPrefix(tag + "-") { return 0 }
        guard primarySubtag(of: tag) == primarySubtag(of: preferred) else { return nil }
        return 1
    }

    private static func primarySubtag(of tag: String) -> String {
        guard let separator = tag.firstIndex(of: "-") else { return tag }
        return String(tag[tag.startIndex..<separator])
    }
}

/// A directory's language-tagged subtitle files, indexed once. Read sites that
/// walk a listing song by song would otherwise rescan the whole directory for
/// every song in it; this codebase has paid that quadratic cost before.
/// Sites that already build a `SidecarDirectoryIndex` get the same tier from
/// it instead.
public struct LanguageTaggedLyricsIndex: Sendable {
    private struct Candidate: Sendable {
        let name: String
        let tag: String
        let stem: String
    }

    private let candidatesByBaseName: [String: [Candidate]]
    private let audioStems: Set<String>
    private let preferredLanguages: [String]

    public var isEmpty: Bool { candidatesByBaseName.isEmpty }

    public init(fileNames: [String], preferredLanguages: [String] = Locale.preferredLanguages) {
        var candidatesByBaseName: [String: [Candidate]] = [:]
        var audioStems: Set<String> = []
        for name in fileNames {
            let fileExtension = (name as NSString).pathExtension.lowercased()
            if PrimuseConstants.supportedAudioExtensions.contains(fileExtension)
                || PrimuseConstants.supportedStreamDescriptorExtensions.contains(fileExtension) {
                audioStems.insert((name as NSString).deletingPathExtension.lowercased())
                continue
            }
            guard let components = LyricsSidecarSelectionPolicy
                .languageTaggedComponents(ofSidecarNamed: name) else { continue }
            candidatesByBaseName[components.baseName.lowercased(), default: []].append(
                Candidate(
                    name: name,
                    tag: components.tag,
                    stem: (name as NSString).deletingPathExtension.lowercased()
                )
            )
        }
        self.candidatesByBaseName = candidatesByBaseName
        self.audioStems = audioStems
        self.preferredLanguages = preferredLanguages
    }

    /// The file name, in its listed spelling, of the language-tagged document
    /// that belongs to `baseName`.
    public func bestMatch(baseName: String) -> String? {
        guard let candidates = candidatesByBaseName[baseName.lowercased()] else { return nil }
        let usable = candidates.filter { !audioStems.contains($0.stem) }
        guard let choice = LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: usable.map(\.tag),
            preferredLanguages: preferredLanguages
        ) else { return nil }
        return usable[choice].name
    }

    /// The file name, in its listed spelling, of the track that translates
    /// `primaryName`.
    public func translationTrack(forPrimary primaryName: String, baseName: String) -> String? {
        guard let primary = LyricsSidecarSelectionPolicy
                .languageTaggedComponents(ofSidecarNamed: primaryName),
              primary.baseName.caseInsensitiveCompare(baseName) == .orderedSame,
              LyricsSidecarSelectionPolicy.marksOriginalTrack(primary.tag),
              let candidates = candidatesByBaseName[baseName.lowercased()] else { return nil }
        let usable = candidates.filter {
            !audioStems.contains($0.stem)
                && $0.name.caseInsensitiveCompare(primaryName) != .orderedSame
        }
        guard let choice = LyricsSidecarSelectionPolicy.translationTrackIndex(
            originalTag: primary.tag,
            tags: usable.map(\.tag),
            preferredLanguages: preferredLanguages
        ) else { return nil }
        return usable[choice].name
    }
}

/// Folds a subtitle translation track into the original track it was made
/// from. The two documents come out of one tool run over one cue list, so the
/// translation is not a second lyric document but the line underneath each
/// original line — the same presentation a bilingual LRC gets.
///
/// This lives beside the selection policy because the two answer one
/// question between them: which of a song's subtitle files is its document,
/// and what the rest of that family is for.
public enum LyricsTranslationTrackPolicy {
    /// The cue times are written by the same tool from the same timeline, so
    /// this only has to absorb the millisecond rounding of two containers.
    private static let timestampTolerance: TimeInterval = 0.05

    /// Below this share of translated lines the two documents are not the
    /// same timeline at all — human-authored subtitles for the same song sit
    /// on their own cue boundaries and would leave a handful of lines
    /// translated at random.
    private static let minimumCoverage = 0.6

    public static func merging(
        primary: [LyricLine],
        translation: [LyricLine],
        languageCode: String?
    ) -> [LyricLine]? {
        guard !primary.isEmpty,
              !translation.isEmpty,
              primary.allSatisfy(\.isSynchronized),
              translation.allSatisfy(\.isSynchronized) else { return nil }

        let merged = LyricManualTranslationPolicy.merging(
            originalLines: primary,
            translatedLines: translation,
            translationLanguageCode: languageCode,
            // `.embeddedField` is the provenance of a translation the source
            // document itself carried, which is exactly what this is: it
            // survives a re-read of the source the way an embedded
            // `TRANSLATEDLYRICS` field does, and a save that can serialize it
            // turns it into bilingual LRC. A new case would have neither, and
            // an older build could not decode a cached or synced document
            // that carried it.
            source: .embeddedField,
            makePreferred: true,
            timestampTolerance: timestampTolerance
        )
        guard merged.count == primary.count else { return nil }

        var result = merged
        var contentLineCount = 0
        var translatedLineCount = 0
        for index in primary.indices {
            let original = primary[index]
            // A cue that already carried its own second line is the document's
            // own translation. A machine-translated companion must not push it
            // aside, and a document translated throughout therefore never
            // reaches the coverage gate below.
            if original.manualTranslation != nil { result[index] = original }
            guard !original.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            contentLineCount += 1
            if original.manualTranslation == nil, result[index].manualTranslation != nil {
                translatedLineCount += 1
            }
        }
        guard contentLineCount > 0,
              Double(translatedLineCount) >= Double(contentLineCount) * minimumCoverage else {
            return nil
        }
        return result
    }
}
