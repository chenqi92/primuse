import Foundation

/// `LibraryCatalogScaleTests` 的全部预算(PLAN §5)。改预算要在这里写明理由。
///
/// 时间预算按编译机(Mac mini M 系列)标定。随曲库规模线性增长的项(整表排序、遍历)
/// 在缩小规模运行时按比例缩放,但不低于各自的下限;与规模无关的项(打开、首页物化、
/// 专辑歌曲)不缩放。
enum LibraryCatalogScaleBudgets {
    /// 预算标定所用的规模。
    static let referenceSongCount = 500_000
    /// 数据库文件每首歌的字节数上限(含全部索引与分组表)。
    static let databaseBytesPerSong = 900
    /// 从合成 `library-songs.sqlite` 迁移(导入 + 建索引 + 分组整库重建)的总时长,50 万首。
    /// 艺人、专辑、文件名三条本地化排序索引不算在内:它们在迁移后由 `buildPendingSortIndexes`
    /// 在后台补建(规模测试另记 `build.backgroundSortIndexes`)。
    static let migrationSeconds = 30.0
    /// 迁移时长只在优化编译里判失败(`swift test -c release -Xswiftc -enable-testing`);Debug 照样量、
    /// 照样打印。理由(2026-11-23,用户决定):未优化编译里 Swift 泛型与字符串的开销把迁移放大约 1.5 倍
    /// (同一份代码 10 万首 Debug 9.9–10.3 s、Release 6.6 s),而用户设备上跑的是优化编译。
    static var enforcesMigrationTime: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
    /// 50 万首整轮远超 45 s,CI 用 10 万首(整轮 < 45 s);验收时设环境变量
    /// `PRIMUSE_CATALOG_SCALE_SONGS=500000` 跑全量。
    static let ciSongCount = 100_000

    // MARK: Memory (MiB)

    /// 走完标准动作并释放缓存后,footprint 相对走之前的增长。
    static let retainedGrowthMiB = 32.0
    /// 走的过程中 footprint 的峰值增长。
    static let peakGrowthMiB = 128.0
    /// 迁移(导入 + 建索引 + 分组重建)过程中 footprint 的峰值增长:内存以一批为界,与曲库大小无关。
    static let migrationPeakGrowthMiB = 128.0

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
    /// 一批增量写入(数百首 upsert + 删除,含跨源同名专辑),包括分组的增量维护。
    static let incrementalWriteMilliseconds = 1_000.0
    /// 扫描入库一批 2000 首新歌(含分组的增量维护)。
    static let ingestWriteMilliseconds = 2_000.0
    /// 改一首歌的标签。
    static let singleEditMilliseconds = 50.0
    /// 专辑详情:取一张专辑的可见歌曲(按碟号曲号)并物化;封面回退那一首(PLAN §5)。
    static let albumSongsMilliseconds = 10.0

    // MARK: Latency (ms) — scale with the library

    /// 有覆盖索引的排序(标题、艺人、专辑、加入时间,升降各一)取整表行号。
    static let indexedSortMilliseconds = 400.0
    /// 没有索引的排序(文件名、时长、年份、格式、播放次数、来源、码率…):ORDER BY 走临时文件
    /// (文件名多核排序),结果缓存到下一次修订。量的是冷缓存。
    static let unindexedSortMilliseconds = 1_500.0
    /// 计数类(可见、音乐、按源、汇总)。
    static let countMilliseconds = 300.0
    /// 流式遍历整库的 (行号, id, 路径)。
    static let streamAllMilliseconds = 2_000.0
    /// 专辑、艺人键列表(按名字本地化排序,停用源/分出非音乐时按可见统计过滤);艺人的歌。
    static let groupListMilliseconds = 400.0
    /// 流派列表(可见音乐歌曲按流派聚合)。
    static let genreListMilliseconds = 1_500.0

    /// 规模缩放:按比例,但不低于 `floor`。
    static func scaled(_ budget: Double, songCount: Int, floor: Double) -> Double {
        max(floor, budget * Double(songCount) / Double(referenceSongCount))
    }
}
