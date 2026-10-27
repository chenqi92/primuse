import Foundation

/// 有声内容里的视频(#365):视频播客单集、当节目听的网盘视频文件,放画面还是只放声音。
///
/// 音乐 MV 照旧:独立 MV 一直走视频管线,同名 MV 跟着 MV 开关。有声内容的视频默认放画面,
/// 听的人在播放页切到只听声音,车机上一律只放声音。只听声音要靠音频管线解出视频里的音轨,
/// 所以只对 AVFoundation 直接打得开的 MP4/M4V/MOV 开放;MKV 这类要先改写成 MP4 的、HLS 流,
/// 都只能走视频管线,也就不给切换。
public enum SpokenWordVideoPolicy {
    /// 本机记的选择(各台设备各记各的);没记过按 `defaultShowsVideo`。
    public static let preferenceKey = "spokenWordShowsVideo"
    public static let defaultShowsVideo = true

    private static let audioOnlyContainers: Set<VideoFormat> = [.mp4, .m4v, .mov]

    /// 这条视频能不能只放声音。`path` 是本机路径、网盘路径或带 scheme 的地址都行;
    /// 地址里看不出容器(播客 enclosure 常是 `download.php?id=…` 这种)时看
    /// `fallbackExtension`(按 MIME 猜的那个)。地址明说是别的视频容器时不认猜的。
    public static func supportsAudioOnly(path: String, fallbackExtension: String?) -> Bool {
        if let format = VideoFormat.from(fileExtension: pathExtension(of: path)) {
            return audioOnlyContainers.contains(format)
        }
        guard let fallbackExtension, let format = VideoFormat.from(fileExtension: fallbackExtension) else {
            return false
        }
        return audioOnlyContainers.contains(format)
    }

    /// 这一条走视频管线(AVPlayer 放画面)还是音频管线。
    /// - Parameters:
    ///   - isStandaloneVideo: 媒体本体就是视频(独立 MV、视频播客单集、网盘里的视频文件)。
    ///   - hasSidecarVideo: 音频旁边挂着同名 MV。
    ///   - forcesAudioOnly: 车机连着,只出声。
    ///   - videoFailed: 这一条的视频这次已经放失败过,先只放声音,换条目或重新切换时再试。
    public static func usesVideoPipeline(
        isStandaloneVideo: Bool,
        hasSidecarVideo: Bool,
        isSpokenWord: Bool,
        showsSpokenWordVideo: Bool,
        musicVideoModeEnabled: Bool,
        forcesAudioOnly: Bool,
        supportsAudioOnly: Bool,
        videoFailed: Bool = false
    ) -> Bool {
        if isStandaloneVideo {
            // 音乐的独立 MV、只能走视频管线的有声视频,都没有别的出声办法。
            guard isSpokenWord, supportsAudioOnly else { return true }
            return showsSpokenWordVideo && !forcesAudioOnly && !videoFailed
        }
        guard hasSidecarVideo else { return false }
        return musicVideoModeEnabled && !forcesAudioOnly
    }

    /// 播放页上给不给「显示视频 / 只听声音」这颗键。投放出去、车机上画面都不在手机上,不给。
    public static func offersToggle(
        isStandaloneVideo: Bool,
        isSpokenWord: Bool,
        supportsAudioOnly: Bool,
        forcesAudioOnly: Bool,
        isCasting: Bool
    ) -> Bool {
        isStandaloneVideo && isSpokenWord && supportsAudioOnly && !forcesAudioOnly && !isCasting
    }

    static func pathExtension(of path: String) -> String {
        if path.contains("://"), let url = URL(string: path) {
            return url.pathExtension
        }
        return (path as NSString).pathExtension
    }
}
