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

    /// Whether sidecar writeback may serialize into this file at all.
    public static func isWritableDocument(fileName: String) -> Bool {
        PrimuseConstants.supportedLyricsExtensions.contains(fileExtension(of: fileName))
    }

    /// The song's current lyric document among its same-name siblings.
    public static func currentDocument(baseName: String, names: [String]) -> Selection {
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
        guard let best else { return .none }
        return .item(best)
    }

    /// The writable document that replaces a read-only one. A save creates
    /// `<base>.lrc` next to the source document instead of overwriting it.
    /// Returns nil when `targetPath` does not actually end in the document's
    /// extension, because the caller then has no address it may safely rewrite.
    public static func writableReplacement(
        targetPath: String,
        fileName: String
    ) -> (targetPath: String, fileName: String)? {
        let name = fileName as NSString
        let suffix = ".\(name.pathExtension)"
        guard suffix.count > 1,
              targetPath.count >= suffix.count,
              targetPath.suffix(suffix.count).caseInsensitiveCompare(suffix) == .orderedSame else {
            return nil
        }
        return (
            targetPath: String(targetPath.dropLast(suffix.count)) + ".lrc",
            fileName: writableFileName(replacing: fileName)
        )
    }

    /// The name a save uses next to a read-only document.
    public static func writableFileName(replacing fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + ".lrc"
    }

    private static func fileExtension(of fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private static func readPriority(of fileName: String) -> Int {
        PrimuseConstants.readableLyricsExtensions
            .firstIndex(of: fileExtension(of: fileName))
            ?? PrimuseConstants.readableLyricsExtensions.count
    }
}
