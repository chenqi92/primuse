import Foundation

public struct SpokenWordSleepChapter: Equatable, Sendable, Identifiable {
    public var songID: String
    public var title: String
    public var startTime: TimeInterval
    /// Nil means the media item's natural end, including an unknown duration.
    public var endTime: TimeInterval?
    public var id: String { "\(songID)|\(startTime)" }

    public init(songID: String, title: String, startTime: TimeInterval = 0, endTime: TimeInterval? = nil) {
        self.songID = songID; self.title = title; self.startTime = startTime; self.endTime = endTime
    }

    public static func choices(songID: String, title: String, chapters: [MediaChapter]) -> [Self] {
        guard !chapters.isEmpty else { return [Self(songID: songID, title: title)] }
        return chapters.enumerated().map { index, chapter in
            Self(songID: songID, title: chapter.title, startTime: chapter.startTime,
                 endTime: chapter.endTime ?? (index + 1 < chapters.count ? chapters[index + 1].startTime : nil))
        }
    }
}

public struct SpokenWordSleepSelection: Equatable, Sendable {
    public let chapter: SpokenWordSleepChapter
    public private(set) var remainingSongIDs: [String]
    public let chapterRevision: String?

    public init?(chapter: SpokenWordSleepChapter, orderedSongIDs: [String], currentSongID: String,
                 position: TimeInterval, chapterRevision: String?) {
        guard let current = orderedSongIDs.firstIndex(of: currentSongID),
              let target = orderedSongIDs[current...].firstIndex(of: chapter.songID),
              chapter.endTime.map({ $0.isFinite && $0 > chapter.startTime }) ?? true,
              chapter.songID != currentSongID || chapter.endTime.map({ $0 > position }) ?? true else { return nil }
        self.chapter = chapter
        self.remainingSongIDs = Array(orderedSongIDs[current...target])
        self.chapterRevision = chapterRevision
    }

    /// Manual skips past the target or outside this book cancel the selection.
    public mutating func follow(songID: String?) -> Bool {
        guard let songID, let index = remainingSongIDs.firstIndex(of: songID) else { return false }
        remainingSongIDs.removeFirst(index)
        return true
    }

    public func shouldStop(songID: String, position: TimeInterval) -> Bool {
        guard songID == chapter.songID, let end = chapter.endTime else { return false }
        return position.isFinite && position >= end
    }
}
