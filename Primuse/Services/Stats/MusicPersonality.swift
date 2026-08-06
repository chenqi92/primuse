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

    /// 本地化名称 (16 种, 见 Docs/YearlyReport.md §四)。
    var displayName: String {
        switch code {
        case "EOND": return String(localized: "yearly_personality_eond_name")
        case "EONM": return String(localized: "yearly_personality_eonm_name")
        case "EOVD": return String(localized: "yearly_personality_eovd_name")
        case "EOVM": return String(localized: "yearly_personality_eovm_name")
        case "EFND": return String(localized: "yearly_personality_efnd_name")
        case "EFNM": return String(localized: "yearly_personality_efnm_name")
        case "EFVD": return String(localized: "yearly_personality_efvd_name")
        case "EFVM": return String(localized: "yearly_personality_efvm_name")
        case "LOND": return String(localized: "yearly_personality_lond_name")
        case "LONM": return String(localized: "yearly_personality_lonm_name")
        case "LOVD": return String(localized: "yearly_personality_lovd_name")
        case "LOVM": return String(localized: "yearly_personality_lovm_name")
        case "LFND": return String(localized: "yearly_personality_lfnd_name")
        case "LFNM": return String(localized: "yearly_personality_lfnm_name")
        case "LFVD": return String(localized: "yearly_personality_lfvd_name")
        case "LFVM": return String(localized: "yearly_personality_lfvm_name")
        default: return code
        }
    }

    /// 一句话画像。
    var oneLiner: String {
        switch code {
        case "EOND": return String(localized: "yearly_personality_eond_description")
        case "EONM": return String(localized: "yearly_personality_eonm_description")
        case "EOVD": return String(localized: "yearly_personality_eovd_description")
        case "EOVM": return String(localized: "yearly_personality_eovm_description")
        case "EFND": return String(localized: "yearly_personality_efnd_description")
        case "EFNM": return String(localized: "yearly_personality_efnm_description")
        case "EFVD": return String(localized: "yearly_personality_efvd_description")
        case "EFVM": return String(localized: "yearly_personality_efvm_description")
        case "LOND": return String(localized: "yearly_personality_lond_description")
        case "LONM": return String(localized: "yearly_personality_lonm_description")
        case "LOVD": return String(localized: "yearly_personality_lovd_description")
        case "LOVM": return String(localized: "yearly_personality_lovm_description")
        case "LFND": return String(localized: "yearly_personality_lfnd_description")
        case "LFNM": return String(localized: "yearly_personality_lfnm_description")
        case "LFVD": return String(localized: "yearly_personality_lfvd_description")
        case "LFVM": return String(localized: "yearly_personality_lfvm_description")
        default: return ""
        }
    }

    /// Asset 名 ── 跟 Docs/YearlyReport.md §七 命名规则一致。
    var assetName: String { "personality_\(code)" }
}
