import Foundation

/// Google 要求能读取整个 Google Drive 的应用在 2026-11-20 前完成付费的第三方 CASA 评估,
/// Primuse 不做这项评估,改用只能访问用户所选文件的 drive.file 权限。三端的提醒都按这一天
/// 分成「将于」与「已于」两种说法。
public enum GoogleDriveAccessChangePolicy {
    public enum Phase: Equatable, Sendable {
        case upcoming
        case inEffect
    }

    /// 只记公历年月日:泰语、日语等地区的默认日历不是公历,直接拿 `Calendar.current`
    /// 去解释 2026 会落到另一个纪年。
    public static let effectiveDay = DateComponents(year: 2026, month: 11, day: 20)

    /// 生效时刻取用户所在时区这一天的零点,和界面上显示的日期对得上。
    public static func effectiveDate(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: effectiveDay) ?? Date.distantFuture
    }

    public static func phase(now: Date = Date(), timeZone: TimeZone = .current) -> Phase {
        now < effectiveDate(in: timeZone) ? .upcoming : .inEffect
    }
}
