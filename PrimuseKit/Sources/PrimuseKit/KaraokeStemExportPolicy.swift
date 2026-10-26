import Foundation

/// AI 分离好的歌导出成单独的文件(#362):伴奏或人声各写一首。
///
/// 人声就是缓存里的人声轨;伴奏是原曲减去人声轨 —— 卡拉OK舞台上实时消人声用的就是这一减,
/// 这里整首离线算。原曲按分离时同一种解码(同采样率、CUE 分轨同一段)重新解一遍,
/// 和人声轨逐样本对得上,不用再对齐。
public enum KaraokeStemExportPolicy {
    public enum Part: String, CaseIterable, Sendable, Identifiable {
        /// 去掉人声的伴奏。
        case instrumental
        /// 只有人声。
        case vocals

        public var id: String { rawValue }
    }

    /// 存成什么格式。分离工具一般默认给无损 WAV,拿去剪辑、混音再加工不叠加损失;
    /// M4A(AAC)体积约五分之一,拿来听、做铃声够用。
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        /// 44.1 kHz 16 位立体声 WAV。
        case wav
        /// AAC 编码的 M4A。
        case m4a

        public var id: String { rawValue }

        public var fileExtension: String { rawValue }
    }

    /// 导出用的 AAC 码率,从高往低试(编码器在某些采样率下不收高码率)。
    public static func bitRateCandidates() -> [Int] {
        AudioClipExportPolicy.bitRateCandidates(channelCount: 2)
    }

    /// 原曲(某一声道)就地减去人声轨,得到伴奏。两边长度差一点时按短的那份算,多出来的截掉;
    /// 减完超出 ±1 的削到 ±1,编码器不会因此破音。
    public static func subtractVocals(_ vocals: [Float], from mix: inout [Float]) {
        let count = min(mix.count, vocals.count)
        if mix.count > count { mix.removeLast(mix.count - count) }
        mix.withUnsafeMutableBufferPointer { output in
            vocals.withUnsafeBufferPointer { vocal in
                for index in 0..<count {
                    output[index] = min(1, max(-1, output[index] - vocal[index]))
                }
            }
        }
    }

    /// 文件名:「标题 (伴奏) - 艺人.wav」;`partLabel` 是「伴奏」「人声」这样的本地化后缀。
    public static func fileName(title: String, artist: String?, partLabel: String, format: Format) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelled = trimmedTitle.isEmpty ? partLabel : "\(trimmedTitle) (\(partLabel))"
        return AudioClipExportPolicy.fileName(title: labelled, artist: artist, fileExtension: format.fileExtension)
    }
}
