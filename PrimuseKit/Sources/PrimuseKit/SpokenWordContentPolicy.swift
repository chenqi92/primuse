import Foundation

/// What kind of listening an item is for. Music is played as a collection;
/// spoken word is played as one long thing you come back to.
public enum ListeningContentKind: String, Codable, Sendable, CaseIterable {
    case music
    case spokenWord
}

/// Decides whether an item is spoken word (audiobook, 相声/评书, radio drama,
/// lecture) rather than music.
///
/// The rule is deliberately evidence-only: a declared `.m4b` container, a genre
/// that names the category, or the user saying so. **Duration is never used** —
/// a 70-minute DJ set, a live recording and a classical symphony movement are
/// all music, and guessing by length would move them out of the library the
/// listener built.
public enum SpokenWordContentPolicy {
    /// The audiobook container. Nothing else writes it, so it is proof on its
    /// own. `Song.fileFormat` cannot carry it — `.m4b` is stored as its `.m4a`
    /// alias so every decoder keeps a proven extension — which is why callers
    /// pass the path's own extension here.
    public static let audiobookFileExtension = "m4b"

    public static func classify(
        fileExtension: String?,
        genre: String?,
        userOverride: ListeningContentKind? = nil
    ) -> ListeningContentKind {
        // An explicit decision outranks every inference, in both directions:
        // marking a lecture series as music has to stick too.
        if let userOverride { return userOverride }
        if let fileExtension,
           fileExtension.lowercased() == audiobookFileExtension {
            return .spokenWord
        }
        if genreNamesSpokenWord(genre) { return .spokenWord }
        return .music
    }

    /// Convenience for the scan/aggregation paths that hold a whole path.
    public static func classify(
        filePath: String,
        genre: String?,
        userOverride: ListeningContentKind? = nil
    ) -> ListeningContentKind {
        classify(
            fileExtension: (filePath as NSString).pathExtension,
            genre: genre,
            userOverride: userOverride
        )
    }

    public static func genreNamesSpokenWord(_ genre: String?) -> Bool {
        guard let genre else { return false }
        let normalized = genre.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !normalized.isEmpty, normalized.count <= 64 else { return false }
        return spokenWordGenreMarkers.contains { normalized.contains($0) }
    }

    /// Genre spellings that name the category itself rather than a mood. Each
    /// one is long enough that it cannot appear inside an unrelated music
    /// genre. `comedy` is deliberately absent: it covers both 相声 and comedy
    /// *music*, so it would misfile real records.
    private static let spokenWordGenreMarkers: Set<String> = [
        // English and other Latin-script spellings
        "audiobook", "audiobooks", "spokenword", "podcast", "radiodrama",
        "radioplay", "audiodrama", "audiotheatre", "audiotheater", "audiobuch",
        "hörbuch", "horbuch", "livreaudio", "audiolibro", "audiolivro",
        "аудиокнига", "lecture", "speech", "sermon", "storytelling",
        // Chinese categories, including the ones with no Western equivalent
        "有声书", "有声小说", "有声读物", "有声故事", "广播剧", "播客",
        "评书", "相声", "快板", "小品", "曲艺", "说书", "单口", "对口",
        "脱口秀", "讲座", "演讲", "朗读", "朗诵", "故事会", "儿童故事",
        // Japanese and Korean
        "オーディオブック", "朗読", "落語", "오디오북",
    ]
}

/// Where a long recording resumes, and when that position stops being worth
/// keeping.
///
/// This exists because a book, a lecture or a 200-episode 评书 series is
/// listened to across days: the point is not "restore the last session" but
/// "every item remembers where I stopped".
public enum SpokenWordProgressPolicy {
    /// Below this, the listener has effectively not started; resuming there
    /// would be indistinguishable from the beginning and only costs a seek.
    public static let minimumRememberedPosition: TimeInterval = 20

    /// Within this of the end, the item counts as finished and its position is
    /// dropped, so the next play starts over instead of landing on the credits.
    public static let completionTailThreshold: TimeInterval = 30

    /// Resuming rewinds slightly: picking up mid-sentence is disorienting, and
    /// every audiobook player does this.
    public static let resumeRewind: TimeInterval = 5

    /// How many items keep a position. Far more than a listener has in flight,
    /// small enough that the store stays a trivial file.
    public static let maximumRememberedItems = 1000

    /// How often a position is written while playing. Between these, a pause,
    /// a track change, a seek and backgrounding all flush immediately.
    public static let autosaveInterval: TimeInterval = 15

    public static func shouldRemember(
        position: TimeInterval,
        duration: TimeInterval
    ) -> Bool {
        guard position.isFinite, duration.isFinite else { return false }
        guard position >= minimumRememberedPosition else { return false }
        // An unknown duration cannot prove the item was finished, and a long
        // position is still worth keeping for it.
        guard duration > 0 else { return true }
        return position <= duration - completionTailThreshold
    }

    /// The position playback should actually start from, or nil to start at
    /// the beginning.
    public static func resumePosition(
        stored: TimeInterval?,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard let stored, stored.isFinite, stored > 0 else { return nil }
        guard shouldRemember(position: stored, duration: duration) else { return nil }
        return max(0, stored - resumeRewind)
    }
}

/// Skip intervals for spoken word, matching what listeners expect from an
/// audiobook or podcast app: a short step back to re-hear a sentence, a longer
/// one forward to get past a passage.
public enum SpokenWordSkipPolicy {
    public static let backwardInterval: TimeInterval = 15
    public static let forwardInterval: TimeInterval = 30

    /// Position after a skip, clamped so a forward skip past the end stops at
    /// the end rather than wrapping to the next item.
    public static func position(
        from current: TimeInterval,
        offset: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        guard current.isFinite, offset.isFinite else { return max(0, current) }
        let target = current + offset
        guard duration.isFinite, duration > 0 else { return max(0, target) }
        return min(max(0, target), duration)
    }
}
