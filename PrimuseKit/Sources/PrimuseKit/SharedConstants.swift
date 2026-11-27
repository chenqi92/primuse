import Foundation

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
    public static let spokenWordShelfSnapshotKey = "widget.spokenWordShelf"
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

    public static let supportedCoverExtensions = ["jpg", "jpeg", "png", "apng", "webp", "gif"]
    /// Extensions Primuse both reads and writes. Sidecar writeback serializes
    /// LRC or TTML, so only these may be chosen as a write target.
    public static let supportedLyricsExtensions = ["lrc", "ttml"]
    /// Extensions Primuse can read, in the order they win when a song has more
    /// than one. The word-timed and subtitle formats are parsed by content, so
    /// they are discovered and cleaned up next to a song like any other
    /// sidecar. `LyricsSidecarSelectionPolicy` keeps them out of writeback:
    /// saving a document would otherwise put LRC text inside a `.qrc` or a
    /// `.vtt` the user brought along.
    public static let readableLyricsExtensions = supportedLyricsExtensions
        + ["elrc", "lys", "yrc", "qrc", "vtt", "srt", "ass", "ssa", "lyl"]
    /// MP4/M4V/MOV play as they are; the rest are rewritten into MP4 the
    /// first time they play (`MusicVideoCompatibilityPolicy`). `.webm` is
    /// here rather than among the audio formats: it is YouTube's video
    /// container, and a video file taken for a song loses its picture while
    /// an audio-only WebM taken for a video still plays its sound.
    public static let supportedMusicVideoExtensions = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "divx", "flv", "f4v", "wmv",
        "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "rmvb", "rm", "ogv", "3gp", "3g2",
    ]
    public static let supportedStreamDescriptorExtensions: Set<String> = ["strm"]
    public static let folderCoverNames = ["cover", "folder", "album", "front", "artwork"]

    /// Note: `.mp4` is intentionally excluded — it's primarily a video
    /// container, and the SFB AAC-in-MP4 decoder is unreliable for the
    /// kind of mp4 a user typically drops in their music folder (often
    /// extracted-from-video files with non-standard atom layout). Audio
    /// MP4 files should use `.m4a`. Including `.mp4` here led to mid-stream
    /// PCM decode errors that auto-skipped 25%+ of cloud-drive scans.
    ///
    /// `.m4b` is the same ISO base-media container as `.m4a` — audiobooks and
    /// spoken-word recordings are simply tagged with it — so it is carried as
    /// an `AudioFormat.m4a` alias rather than as a format of its own. Every
    /// decoder, cache-name and metadata-parser decision then keeps using the
    /// extension that is already proven on all three platforms.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "m4b", "flac", "wav", "wave", "aiff", "aif", "au", "snd", "caf", "alac",
        "ape", "dsf", "dff", "iso", "ogg", "oga", "opus", "wma", "asf", "wv", "dts", "dtshd", "dts-hd",
        "ac3", "eac3", "ec3", "mlp", "truehd", "thd", "amr", "awb",
        "atrac", "oma", "aa3", "at3", "tak", "tta", "mpc", "mpp", "shn", "speex", "spx", "qoa",
        "m4r", "aifc", "bwf", "mka", "weba", "mp2", "mpa", "mp1", "m2a",
        "w64", "rf64", "bw64", "ra",
        "mod", "xm", "it", "s3m", "stm", "mtm", "ptm", "okt", "669"
    ]

    /// CUE sheets are library descriptors rather than playable files. Source
    /// scanners enumerate them separately and expand their INDEX 01 entries
    /// into virtual Song rows that all point at the referenced audio image.
    public static let supportedCueSheetExtensions: Set<String> = ["cue"]
    public static let supportedVirtualTrackExtensions: Set<String> = ["cue", "iso"]

    /// 歌旁边的那些文件(歌词、封面、CUE、说明文字)的扩展名。有声书服务器的章节路径只是
    /// 「书 id + 章节 id」加一个类型提示,按同目录规则拼出来的 `<章节>.lrc` 一类路径
    /// 不能被认成同一章,否则读歌词会把整章音频当成文字读出来(#304)。
    public static let sidecarFileExtensions: Set<String> = Set(readableLyricsExtensions)
        .union(supportedCoverExtensions)
        .union(supportedCueSheetExtensions)
        .union(["txt", "nfo", "json", "xml"])
}
