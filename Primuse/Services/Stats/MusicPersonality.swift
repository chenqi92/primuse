import Foundation

/// 音乐人格 ── 4 维度二值化, 16 种组合 (类似 MBTI)。
///
/// 维度:
/// - **E / L**: Explorer / Loyalist (探索 vs 死忠)
/// - **O / F**: Omnivore / Focused (杂食 vs 专精)
/// - **N / V**: New / Vintage (追新 vs 怀旧)
/// - **D / M**: Day / Moon (昼伏 vs 夜行)
struct MusicPersonality: Sendable, Equatable {
    enum Exploration: Sendable { case explorer, loyalist }
    enum Diversity: Sendable { case omnivore, focused }
    enum Recency: Sendable { case new, vintage }
    enum DayCycle: Sendable { case day, moon }

    let exploration: Exploration
    let diversity: Diversity
    let recency: Recency
    let dayCycle: DayCycle

    /// 4 字母代码, 文档 / asset name 用。e.g. "EOND"
    var code: String {
        let e = exploration == .explorer ? "E" : "L"
        let o = diversity == .omnivore ? "O" : "F"
        let n = recency == .new ? "N" : "V"
        let d = dayCycle == .day ? "D" : "M"
        return e + o + n + d
    }

    /// 中文名 (16 种, 见 Docs/YearlyReport.md §四)。
    /// 不走 Localizable.strings 是因为名字是设计资产, 跨设备同步, 跟具体 lang
    /// 解耦; 后续可以挪到 strings 里支持 i18n。
    var displayName: String {
        switch code {
        case "EOND": return "城市漫游者"
        case "EONM": return "夜行探险家"
        case "EOVD": return "复古拓荒人"
        case "EOVM": return "月光档案员"
        case "EFND": return "阳光浪客"
        case "EFNM": return "暗夜浪客"
        case "EFVD": return "怀旧浪客"
        case "EFVM": return "黑胶夜游"
        case "LOND": return "阳光博物者"
        case "LONM": return "午夜博物者"
        case "LOVD": return "故纸学究"
        case "LOVM": return "月下守夜人"
        case "LFND": return "阳光专一派"
        case "LFNM": return "月夜专一派"
        case "LFVD": return "复古铁粉"
        case "LFVM": return "黑胶守夜人"
        default: return code
        }
    }

    /// 一句话画像。
    var oneLiner: String {
        switch code {
        case "EOND": return "白天什么风格的新歌都听一耳朵, 停不下来探索"
        case "EONM": return "深夜耳机里永远是新发现, 听过的就翻篇"
        case "EOVD": return "白天挖掘各种老歌冷门曲, 每首都新鲜"
        case "EOVM": return "深夜在年代灰尘里淘宝, 杂食且嗜旧"
        case "EFND": return "一种风格里挑各种新歌, 白天听"
        case "EFNM": return "一种风格里挑各种新歌, 深夜听"
        case "EFVD": return "守一种老风格, 白天里轻盈漫步"
        case "EFVM": return "守一种老风格, 深夜独酌"
        case "LOND": return "围绕几个偏爱艺术家但风格多元, 新歌为主, 白天听"
        case "LONM": return "几个偏爱艺术家, 风格多元, 新歌为主, 深夜版"
        case "LOVD": return "几个老艺术家循环到死, 白天的图书馆感"
        case "LOVM": return "几个老艺术家循环到死, 深夜守候"
        case "LFND": return "死忠少数艺术家 + 单一风格 + 新歌 + 白天"
        case "LFNM": return "死忠 + 单一 + 新歌 + 深夜"
        case "LFVD": return "死忠 + 单一 + 老歌 + 白天"
        case "LFVM": return "死忠 + 单一 + 老歌 + 深夜"
        default: return ""
        }
    }

    /// Asset 名 ── 跟 Docs/YearlyReport.md §七 命名规则一致。
    var assetName: String { "personality_\(code)" }
}
