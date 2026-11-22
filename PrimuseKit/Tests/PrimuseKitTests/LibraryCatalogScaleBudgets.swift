import Foundation

/// `LibraryCatalogScaleTests` 的全部预算(PLAN §5)。改预算要在这里写明理由。
///
/// 时间预算按编译机(Mac mini M 系列)标定。随曲库规模线性增长的项(整表排序、遍历)
/// 在缩小规模运行时按比例缩放,但不低于各自的下限;与规模无关的项(打开、首页物化、
/// 专辑歌曲)不缩放。
enum LibraryCatalogScaleBudgets {
    /// 预算标定所用的规模。
    static let referenceSongCount = 500_000
    /// 整轮超过 45 s 时 CI 用这个规模;设环境变量 `PRIMUSE_CATALOG_SCALE_SONGS=500000` 跑全量。
    static let ciSongCount = 200_000

    // MARK: Memory (MiB)

    /// 走完标准动作并释放缓存后,footprint 相对走之前的增长。
    static let retainedGrowthMiB = 32.0
    /// 走的过程中 footprint 的峰值增长。
    static let peakGrowthMiB = 128.0

    // MARK: Latency (ms) — scale independent

    /// 打开目录、读 meta 与修订号。
    static let openMilliseconds = 100.0
    /// 物化歌曲列表首页 200 行(冷行缓存)。
    static let firstPageMilliseconds = 50.0
    /// 随机一页 200 行(冷行缓存)。
    static let randomPageMilliseconds = 50.0
    /// 按 id 取 5000 首(物化上限)。
    static let maxBatchMaterializationMilliseconds = 400.0
    /// 一个目录的直接子项 / 一个精确路径。
    static let pathQueryMilliseconds = 20.0
    /// 一批增量写入(数百首 upsert + 删除)。
    static let incrementalWriteMilliseconds = 1_000.0

    // MARK: Latency (ms) — scale with the library

    /// 有覆盖索引的排序(标题、艺人、专辑、文件名、加入时间、时长、年份)取整表行号。
    static let indexedSortMilliseconds = 400.0
    /// 没有索引的排序(格式、播放次数、来源、码率…),走临时文件排序。
    static let unindexedSortMilliseconds = 3_000.0
    /// 计数类(可见、音乐、按源、汇总)。
    static let countMilliseconds = 300.0
    /// 流式遍历整库的 (行号, id, 路径)。
    static let streamAllMilliseconds = 2_000.0

    /// 规模缩放:按比例,但不低于 `floor`。
    static func scaled(_ budget: Double, songCount: Int, floor: Double) -> Double {
        max(floor, budget * Double(songCount) / Double(referenceSongCount))
    }
}
