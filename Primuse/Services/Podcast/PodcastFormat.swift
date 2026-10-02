import Foundation
import PrimuseKit

/// 播客界面上的日期、时长、分类名。iPhone、Mac、Apple TV 共用。
enum PodcastFormat {
    /// feed/目录给的分类名:认得出的 Apple 一级分类用本地化名字,认不出的原样。
    static func category(_ name: String) -> String {
        guard let id = PodcastDirectory.genreID(forCategory: name) else { return name }
        return String(localized: String.LocalizationValue(genreKey(id)))
    }

    /// 分类的本地化键。必须拼成普通字符串再交给本地化:直接在键里插值 Int,
    /// 会被当成格式参数(`podcast_genre_%lld`)查不到,还按地区印成「1,324」。
    static func genreKey(_ id: Int) -> String {
        "podcast_genre_" + String(id)
    }

    /// 一周内说「今天/昨天/星期三」,再早写日期,不是今年的带年份。
    static func date(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "podcast_date_today") }
        if calendar.isDateInYesterday(date) { return String(localized: "podcast_date_yesterday") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    /// 「1 小时 28 分」「48 分钟」。不到一分钟的按一分钟算。
    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        String(format: String(localized: "podcast_remaining_format"), duration(seconds) ?? "1 min")
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
