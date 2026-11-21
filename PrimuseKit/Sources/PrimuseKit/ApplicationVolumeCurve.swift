import Foundation

/// 「应用内音量」滑块位置与增益的换算(#463)。
///
/// 增益直接按位置线性走时,能听出差别的范围全挤在左边一小段:-20 dB 只在 10% 处。
/// 按位置的平方给增益,半格约 -12 dB、三成约 -21 dB,低音量那头才拖得细。
public enum ApplicationVolumeCurve {
    public static func gain(forPosition position: Double) -> Float {
        guard position.isFinite else { return 1 }
        let clamped = min(max(position, 0), 1)
        return Float(clamped * clamped)
    }

    public static func position(forGain gain: Float) -> Double {
        guard gain.isFinite else { return 1 }
        return Double(min(max(gain, 0), 1)).squareRoot()
    }
}
