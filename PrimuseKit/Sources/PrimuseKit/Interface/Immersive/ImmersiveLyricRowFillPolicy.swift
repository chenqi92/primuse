import Foundation

/// 当前歌词逐字填充在**换行**时怎么推进。
///
/// 旧实现把整段文字当成一块矩形来遮罩:一行歌词被折成两行后,进度 p 会同时把
/// 上下两行的左侧 p 都点亮,看起来就是"上下一起亮"。实际的阅读顺序是先走完
/// 第一行再走第二行,所以填充必须按行分段推进。
public enum ImmersiveLyricRowFillPolicy {
    /// 整段文字被折成了几行。单行高度未知(尚未量出)时按一行处理,
    /// 退化成旧行为而不是画错。
    public static func rowCount(totalHeight: Double, rowHeight: Double) -> Int {
        guard rowHeight > 0, totalHeight > 0 else { return 1 }
        return max(1, Int((totalHeight / rowHeight).rounded()))
    }

    /// 第 `row` 行应该被填充的比例:整行进度平均分配到各行,
    /// 前面的行先填满,当前行填余量,后面的行还没轮到。
    public static func fill(progress: Double, row: Int, rowCount: Int) -> Double {
        guard rowCount > 1 else { return clamped(progress) }
        guard row >= 0, row < rowCount else { return 0 }
        return clamped(clamped(progress) * Double(rowCount) - Double(row))
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
