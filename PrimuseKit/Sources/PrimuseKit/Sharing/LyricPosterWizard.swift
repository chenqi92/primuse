import Foundation

/// 引导式做海报的步骤。
///
/// 单页编辑是常驻形态；引导只在第一次、或用户主动选择时走一遍，把"这个
/// 功能能改哪些东西"一次讲清楚。两者改的是同一份状态，所以任何一步退出
/// 都不会丢已经调好的内容。
public enum LyricPosterWizardStep: String, CaseIterable, Sendable, Identifiable {
    /// 选哪几句。
    case lines
    /// 写一句自己的话。
    case note
    /// 选风格与画幅。
    case style
    /// 选动静、存相册还是分享。
    case export

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .lines: return "lyric_poster_step_lines"
        case .note: return "lyric_poster_step_note"
        case .style: return "lyric_poster_step_style"
        case .export: return "lyric_poster_step_export"
        }
    }

    public var symbolName: String {
        switch self {
        case .lines: return "text.quote"
        case .note: return "square.and.pencil"
        case .style: return "paintpalette"
        case .export: return "square.and.arrow.up"
        }
    }
}

public enum LyricPosterWizardPolicy {
    public static let steps = LyricPosterWizardStep.allCases

    /// 没选歌词就没有海报可言，这一步必须过；其余几步都可以跳过 ——
    /// 不想写感想的人不该被拦在流程里。
    public static func canAdvance(from step: LyricPosterWizardStep, selectionCount: Int) -> Bool {
        switch step {
        case .lines: return selectionCount > 0
        case .note, .style, .export: return true
        }
    }

    public static func next(after step: LyricPosterWizardStep) -> LyricPosterWizardStep? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    public static func previous(before step: LyricPosterWizardStep) -> LyricPosterWizardStep? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    public static func index(of step: LyricPosterWizardStep) -> Int {
        steps.firstIndex(of: step) ?? 0
    }

    /// 进度条用的 0…1。最后一步是满格，而不是"还差一格"。
    public static func progress(at step: LyricPosterWizardStep) -> Double {
        guard steps.count > 1 else { return 1 }
        return Double(index(of: step) + 1) / Double(steps.count)
    }

    public static func isLast(_ step: LyricPosterWizardStep) -> Bool {
        next(after: step) == nil
    }
}
