import Foundation

public enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

/// 队列页那颗「播放方式」键(#338):随机与循环两个开关合成一颗,点一下换下一种。
/// 状态仍是播放器上那两个开关,这里只管怎么读成一种、怎么换到下一种。
public enum PlaybackOrderMode: String, CaseIterable, Sendable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle

    /// 两个开关现在落在哪一种上。单曲循环决定实际播什么,随机同时开着也算单曲循环。
    public init(shuffleEnabled: Bool, repeatMode: RepeatMode) {
        if repeatMode == .one {
            self = .repeatOne
        } else if shuffleEnabled {
            self = .shuffle
        } else if repeatMode == .all {
            self = .repeatAll
        } else {
            self = .sequential
        }
    }

    /// 点一下换到的下一种:顺序 → 列表循环 → 单曲循环 → 随机 → 顺序。队列不到两首、随机打不开时跳过随机。
    public func next(allowsShuffle: Bool) -> PlaybackOrderMode {
        let order = Self.allCases
        var index = order.firstIndex(of: self) ?? 0
        repeat {
            index = (index + 1) % order.count
        } while order[index] == .shuffle && !allowsShuffle
        return order[index]
    }

    /// 换到这一种后两个开关的值。进随机时原来是单曲循环就改成列表循环(随机播完一轮接着来),
    /// 原来是顺序或列表循环的照旧。
    public func settings(from currentRepeat: RepeatMode) -> (shuffleEnabled: Bool, repeatMode: RepeatMode) {
        switch self {
        case .sequential: (false, .off)
        case .repeatAll: (false, .all)
        case .repeatOne: (false, .one)
        case .shuffle: (true, currentRepeat == .one ? .all : currentRepeat)
        }
    }

    public var symbolName: String {
        switch self {
        case .sequential: "list.number"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        }
    }
}

public struct PlaybackState: Codable, Sendable {
    public var currentSongID: String?
    public var songTitle: String?
    public var artistName: String?
    public var albumTitle: String?
    public var fileFormat: String?
    public var coverArtData: Data? // small thumbnail < 100KB
    /// Filename of cover image stored in the App Group shared container (for Widget rendering)
    public var coverImageName: String?
    public var isPlaying: Bool
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var queueSongIDs: [String]
    /// Optional for backward-compatible decoding of snapshots written by
    /// versions before Internet radio support.
    public var playbackKind: PlaybackKind?
    public var radioStationID: String?
    /// Optional for backward-compatible decoding of snapshots written before
    /// the interactive desktop controls exposed repeat state.
    public var repeatMode: RepeatMode?
    /// Whether the current song is in the "Liked" system playlist. Optional so
    /// snapshots written before the lock-screen like button still decode.
    /// The widget can only render the heart, never resolve it — the library
    /// lives in the app sandbox, so the app has to publish it here.
    public var isLiked: Bool?
    /// Time at which `currentTime` was sampled. Optional so snapshots from
    /// older app versions continue to decode.
    public var updatedAt: Date?
    /// Set while a spoken-word item plays: the widget draws skips instead of
    /// track buttons and the book instead of the album. Optional, so older
    /// snapshots decode as music.
    public var spokenWord: SpokenWordPlaybackInfo?

    public init(
        currentSongID: String? = nil,
        songTitle: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        fileFormat: String? = nil,
        coverArtData: Data? = nil,
        coverImageName: String? = nil,
        isPlaying: Bool = false,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        queueSongIDs: [String] = [],
        playbackKind: PlaybackKind? = nil,
        radioStationID: String? = nil,
        repeatMode: RepeatMode? = nil,
        isLiked: Bool? = nil,
        updatedAt: Date? = nil,
        spokenWord: SpokenWordPlaybackInfo? = nil
    ) {
        self.currentSongID = currentSongID
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.fileFormat = fileFormat
        self.coverArtData = coverArtData
        self.coverImageName = coverImageName
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.queueSongIDs = queueSongIDs
        self.playbackKind = playbackKind
        self.radioStationID = radioStationID
        self.repeatMode = repeatMode
        self.isLiked = isLiked
        self.updatedAt = updatedAt
        self.spokenWord = spokenWord
    }

    public var isLiveStream: Bool { playbackKind == .liveRadio }

    public var isSpokenWord: Bool { spokenWord != nil && !isLiveStream }

    /// The station actually playing — not one selected but stopped, nor one
    /// still connecting. Widgets mark it the way the app's radio page does.
    public var playingRadioStationID: String? {
        isLiveStream && isPlaying ? radioStationID : nil
    }

    /// The item actually playing when it is not a station — a podcast
    /// episode, a chapter of a book. Widgets turn its play key into pause.
    public var playingItemID: String? {
        !isLiveStream && isPlaying ? currentSongID : nil
    }

    /// The way of listening the current item belongs to, for the symbol a
    /// widget names it with. A podcast file kept in a music source reads as
    /// spoken word: only subscribed episodes carry the podcast id.
    public var listeningSpace: ListeningSpace {
        if isLiveStream { return .radio }
        if let id = currentSongID, PodcastIdentity.isEpisodeID(id) { return .podcast }
        return isSpokenWord ? .spokenWord : .music
    }

    /// The book whose chapter is actually playing.
    public var playingSpokenWordBookID: String? {
        isSpokenWord && isPlaying ? spokenWord?.bookID : nil
    }

    public static func load() -> PlaybackState? {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = defaults.data(forKey: PrimuseConstants.playbackStateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PlaybackState.self, from: data)
    }

    public func save() {
        var snapshot = self
        if snapshot.updatedAt == nil {
            snapshot.updatedAt = Date()
        }
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: PrimuseConstants.playbackStateKey)
    }

    public static func clear() {
        UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier)?.removeObject(forKey: PrimuseConstants.playbackStateKey)
    }
}
